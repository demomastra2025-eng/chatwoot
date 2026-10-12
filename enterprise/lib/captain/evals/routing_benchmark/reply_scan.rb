# frozen_string_literal: true

# Looks for internal material in the final text a patient would read: runtime markers, tool names, IDs, JSON,
# English system words, wording of the agent instructions and canned or third-person text of the council. The scan is
# deterministic and conservative: a Latin word is a finding only when it is not a brand or term that the workspace or
# the customer used themselves, and an uppercase abbreviation (HPV, PCR) is a finding only when it is a system one.
#
#   reserved_token       conversation_handoff, plan_request, handoff_to_assistant_7, assistant_12 ...
#   tool_name            an ID of the tool registry (faq_lookup, create_appointment, handoff)
#   identifier           a UUID, "#123", "id 123", "appointment_id", an unknown snake_case token
#   json                 a JSON object or array, a YAML-like mapping, a code fence
#   latin                a Latin word that is neither allowed nor typed by the customer
#   instruction_overlap  five words in a row that an agent instruction or routing description contains
#   third_person         "Пользователь сообщает ...", "Пайдаланушы ..." (the council paraphrased the customer)
#   role_fragment        "дочка — Как зовут ...", "не указан — ...", "Жанна Оспанова — Вы имеете в виду ..."
#   composer_phrase      canned council text ("Часть запроса требует дополнительной проверки")
class Captain::Evals::RoutingBenchmark::ReplyScan
  KINDS = %i[reserved_token tool_name identifier json latin instruction_overlap third_person role_fragment composer_phrase].freeze
  SHINGLE_SIZE = 5

  RESERVED_TOKEN = /(?<![\p{L}\p{N}_])(?:conversation_handoff\w*|response_cancelled|plan_request|manage_agent_tasks|handoff_to_assistant_?\d*|
                      (?:assistant|scenario)_\d+|agent_tasks|part_refs|captain_request_id)(?![\p{L}\p{N}_])/ix
  SNAKE_CASE = /(?<![\p{L}\p{N}_])[a-z][a-z0-9]*(?:_[a-z0-9]+)+(?![\p{L}\p{N}_])/
  IDENTIFIER = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}|\#\d+|(?<![\p{L}\d])id\s*[:=\#]?\s*\d+|
                (?<![\p{L}\d])(?:appointment|resource|service|contact|deal|conversation|patient|assistant)[_ -]?id(?![\p{L}\d])/ix
  JSON_LIKE = /```|[{\[]\s*["'][^"'\n]{1,40}["']\s*:|\{\s*[a-z_]+\s*:\s*[^}\n]{0,80}\}/i
  LATIN_WORD = /\p{Latin}[\p{Latin}\p{N}_'-]*/
  # Uppercase abbreviations are medical or brand terms unless they are system words.
  SYSTEM_ABBREVIATIONS = %w[ID API JSON UUID HTTP HTTPS URL SQL NULL NIL NAN UTC TRUE FALSE YAML XML HTML LLM GPT TOOL].freeze
  ALLOWED_LATIN = %w[kaspi qr whatsapp telegram instagram email e-mail mail sms pdf wifi wi-fi].freeze

  THIRD_PERSON = /(?<!\p{L})пользовател\p{L}*\s+(?:сообщает|сообщил\p{L}*|просит|попросил\p{L}*|спрашивает|спросил\p{L}*|хочет|
                   хотел\p{L}*|интересуется|уточняет|запрашивает|обращается|отказывается|подтвердил\p{L}*|подтверждает|
                   указал\p{L}*|отметил\p{L}*)|(?<!\p{L})пайдаланушы\p{L}*/ix
  ROLE_WORDS = 'дочк[аи]|дочь|сын|мама|мать|папа|отец|муж|жена|супруг\p{L}*|ребён\p{L}+|ребен\p{L}+|собеседни\p{L}*|' \
               'не\s+указан\p{L}*|неизвестн\p{L}+|әңгімелесуші\p{L}*'
  ROLE_FRAGMENT = /(?:\A|\n|[.!?;:]\s+|,\s+)(?:#{ROLE_WORDS})\s*[—–]\s*\S/i
  NAME_QUESTION_FRAGMENT = /(?<!\p{L})\p{Lu}\p{Ll}+(?:\s+\p{Lu}\p{Ll}+)?\s+[—–]\s+(?:Вы\s|Как\s|Подтвердите|Уточните|Для\s+кого|Какой|Какую)/
  COMPOSER_PHRASES = [
    /Часть\s+запроса\s+требует\s+дополнительной\s+проверки/i, /Не\s+удалось\s+завершить\s+обработку\s+запроса/i,
    /Подтвердите\s+действие\s+по\s+запросу\s*«/i, /Остаётся\s+открытым:/i
  ].freeze

  class << self
    # Findings for one reply: [{ kind:, matches: [...] }, ...], one entry per kind.
    # tool_ids:   registry tool IDs, to name a token a tool
    # allowed:    Latin words that the workspace or the customer used (case-insensitive)
    # shingles:   Set from .shingles, five-word runs of the agent instructions
    # latin_ok:   skip the Latin check (the customer writes in Latin script)
    def call(text, tool_ids: [], allowed: [], shingles: Set.new, latin_ok: false)
      new(text, tool_ids: tool_ids, allowed: allowed, shingles: shingles, latin_ok: latin_ok).findings
    end

    # Five-word runs of the given instruction texts, normalised for comparison.
    def shingles(texts)
      Array(texts).each_with_object(Set.new) do |text, set|
        normalized_words(text).each_cons(SHINGLE_SIZE) { |run| set << run.join(' ') }
      end
    end

    # The Latin words of the given texts, lower-cased, for the allowed list.
    def latin_words(*texts)
      texts.flatten.compact.flat_map { |text| text.to_s.scan(LATIN_WORD).map { |word| trim(word).downcase } }.uniq
    end

    def normalized_words(text)
      text.to_s.downcase.tr('ё', 'е').scan(/[\p{L}\p{N}]+/)
    end

    def trim(word) = word.sub(/['-]+\z/, '')
  end

  def initialize(text, tool_ids:, allowed:, shingles:, latin_ok:)
    @text = text.to_s
    @tool_ids = Set.new(tool_ids.map(&:to_s))
    @allowed = Set.new((ALLOWED_LATIN + Array(allowed)).map { |word| word.to_s.downcase })
    @shingles = shingles
    @latin_ok = latin_ok
  end

  def findings
    return [] if @text.strip.empty?

    found = Hash.new { |hash, kind| hash[kind] = [] }
    found[:reserved_token].concat(scan(RESERVED_TOKEN))
    found[:identifier].concat(scan(IDENTIFIER))
    found[:json].concat(scan(JSON_LIKE))
    snake_case(found)
    latin_words_in_text.each { |word| (@tool_ids.include?(word.downcase) ? found[:tool_name] : found[:latin]) << word }
    found[:instruction_overlap].concat(overlap)
    found[:third_person].concat(scan(THIRD_PERSON))
    found[:role_fragment].concat(scan(ROLE_FRAGMENT) + scan(NAME_QUESTION_FRAGMENT))
    found[:composer_phrase].concat(COMPOSER_PHRASES.flat_map { |pattern| scan(pattern) })
    KINDS.filter_map { |kind| { kind: kind, matches: found[kind].uniq.first(5) } if found[kind].any? }
  end

  private

  def scan(pattern)
    @text.to_enum(:scan, pattern).map { Regexp.last_match(0).strip }
  end

  # A snake_case token that is not a runtime marker is a tool name when the registry knows it, else an identifier.
  def snake_case(found)
    scan(SNAKE_CASE).each do |token|
      next if found[:reserved_token].include?(token)

      (@tool_ids.include?(token) ? found[:tool_name] : found[:identifier]) << token
    end
  end

  def latin_words_in_text
    return [] if @latin_ok

    @text.scan(LATIN_WORD).filter_map do |word|
      token = self.class.trim(word)
      # A snake_case token is a marker, tool name or identifier (see #snake_case); a token with digits is a code ("B12").
      next if token.length < 2 || token.match?(/\d/) || token.include?('_') || @allowed.include?(token.downcase)
      next if token.split('-').all? { |part| @allowed.include?(part.downcase) }
      next if abbreviation?(token) && SYSTEM_ABBREVIATIONS.exclude?(token)

      token
    end
  end

  def abbreviation?(token)
    token.length <= 6 && token == token.upcase
  end

  def overlap
    return [] if @shingles.empty?

    self.class.normalized_words(@text).each_cons(SHINGLE_SIZE).filter_map do |run|
      joined = run.join(' ')
      joined if @shingles.include?(joined)
    end
  end
end
