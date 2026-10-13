# frozen_string_literal: true

# Looks for internal material in the final text a patient would read: runtime markers, tool names, IDs, JSON,
# English system words, wording of the agent instructions and canned or third-person text of the council. The scan is
# deterministic and conservative: a Latin word is a finding only when it is not a brand or term that the workspace or
# the customer used themselves, and an uppercase abbreviation (HPV, PCR) is a finding only when it is a system one.
#
#   reserved_token       conversation_handoff, plan_request, handoff_to_assistant_7, assistant_12 ...
#   tool_name            an ID of the tool registry (faq_lookup, create_appointment, handoff)
#   identifier           a UUID, "#123", "id 123", "appointment_id", an unknown snake_case token, a numbered booking
#                        ("Запись №4821", "Номер записи: 4821") and a number equal to the id of a record the turn handled
#   json                 a JSON object or array, a YAML-like mapping, a code fence
#   latin                a Latin word that is neither allowed nor typed by the customer
#   instruction_overlap  five words in a row that an agent instruction or routing description contains, unless every long word of the run is
#                        a word of the dialogue's own topic (the customer's words, the knowledge base, the names of doctors and services:
#                        "осмотр для справки в сад" is what the patient asked about, not a copied instruction)
#   third_person         "Пользователь сообщает ...", "Пайдаланушы ..." (the council paraphrased the customer)
#   role_fragment        "дочка — Как зовут ...", "не указан — ...", "Жанна Оспанова — Вы имеете в виду ..." (a family role
#                        followed by a time, a date or a doctor is a recap and no fragment)
#   composer_phrase      canned council text ("Часть запроса требует дополнительной проверки")
#   agent_name           the name of a workspace agent used as a name: in quotes («Запись к врачу») or after "агент". The bare name
#                        of an agent is an ordinary word ("Диагностика", "Администратор") and no finding
#   stock_text           a sentence of the runtime's locale files that is shown to a patient instead of an agent reply (StockText)
#   tool_error           an English sentence of a runtime tool error ("This agent handoff is not allowed")
class Captain::Evals::RoutingBenchmark::ReplyScan
  KINDS = %i[reserved_token tool_name identifier json latin instruction_overlap third_person role_fragment composer_phrase
             agent_name stock_text tool_error].freeze
  SHINGLE_SIZE = 5
  # A word of this many letters or more is a content word of a run; a word is matched with the words of the topic by its stem (the word
  # without its last two letters, but at least STEM_LENGTH letters), which survives Russian and Kazakh case endings.
  CONTENT_WORD_LENGTH = 4
  STEM_LENGTH = 4

  RESERVED_TOKEN = /(?<![\p{L}\p{N}_])(?:conversation_handoff\w*|response_cancelled|plan_request|manage_agent_tasks|
                      (?:handoff|transfer)_to_\w+|(?:assistant|agent|scenario)_\d+|agent_tasks|part_refs|captain_request_id)
                      (?![\p{L}\p{N}_])/ix
  TOOL_ERROR = Regexp.union(
    /handoff\s+(?:is\s+)?not\s+allowed/i, /routing\s+changed/i, /no\s+longer\s+available/i, /requires\s+a\s+confirmed/i,
    /mutation[_\s]retry[_\s]blocked/i, /tool-call\s+loop/i, /not\s+enabled\s+for\s+this\s+assistant/i, /conversation\s+not\s+found/i,
    /failed\s+to\s+hand\s?off/i, /technical\s+failure/i
  )
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
  # A placeholder role is a leak whatever follows the dash. A family role is one only when a question or an instruction
  # follows ("дочка — Как зовут ребёнка?"): "мама — терапевт, 15 октября в 12:00" is a recap of a family booking.
  PLACEHOLDER_ROLES = 'собеседни\p{L}*|не\s+указан\p{L}*|неизвестн\p{L}+|әңгімелесуші\p{L}*'
  FAMILY_ROLES = 'дочк[аи]|дочь|сын|мама|мать|папа|отец|муж|жена|супруг\p{L}*|ребён\p{L}+|ребен\p{L}+'
  ASKING = '(?:Как|Какая|Какой|Какое|Какую|Какие|Когда|Для\s+кого|Уточните|Подтвердите|Подскажите|Назовите|Укажите|Напишите|' \
           'имя|дата\s+рождения|ФИО)(?![\p{L}])'
  ROLE_FRAGMENT = /(?:\A|\n|[.!?;:]\s+|,\s+)(?:(?:#{PLACEHOLDER_ROLES})\s*[—–]\s*\S|(?:#{FAMILY_ROLES})\s*[—–]\s*#{ASKING})/i
  # "Запись №4821", "заявка № 12345", "№ 305": a number sign with three digits or more is an identifier, unless the customer or the
  # workspace wrote that number themselves ("кабинет №305").
  NUMBER_SIGN = /№\s*\d{3,}/
  # "Номер вашей записи: 4821": the booking number, which in this system is the database id.
  RECORD_NUMBER = /(?<!\p{L})номер\p{L}*\s+(?:\p{L}+\s+){0,2}запис\p{L}*[^\p{L}\d\n]{0,4}\d+/i
  # A number that is no time, date, price or amount: not next to ":", "/" or "-", not part of a decimal or a date ("1.5",
  # "15.10.2026"), not the tail of a grouped number ("12 500"), not followed by a unit. A full stop after it is the end of
  # the sentence ("Ваша запись 4821.").
  STANDALONE_NUMBER = %r{(?<![\d:/-])(?<!\d[.,])(?<!\d\s)\d{3,}(?![\d:/-])(?![.,]\d)(?!\s?(?:час|мин|₸|тг|тенге|руб|%|мг|мл|лет|год|сум|кг))}i
  MIN_ID_DIGITS = 3
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
    # internal_ids:  database ids the turn handled (appointment rows, conversation, contact, ids in tool results); a
    #                standalone number equal to one of them is an identifier
    # known_numbers: numbers (strings) the customer or the workspace wrote themselves; never an identifier
    # agent_names:   the names of the workspace agents, for the `agent_name` kind
    # domain_words:  Set from .word_stems, the words of the dialogue's own topic, so that an instruction run made of them is no overlap
    def call(text, tool_ids: [], allowed: [], shingles: Set.new, latin_ok: false, internal_ids: [], known_numbers: [], agent_names: [],
             domain_words: Set.new)
      new(text, tool_ids: tool_ids, allowed: allowed, shingles: shingles, latin_ok: latin_ok, internal_ids: internal_ids,
                known_numbers: known_numbers, agent_names: agent_names, domain_words: domain_words).findings
    end

    # Every prefix of STEM_LENGTH letters or more of every word of the given texts: a word of a reply belongs to the topic when its stem
    # is one of them.
    def word_stems(*texts)
      texts.flatten.compact.each_with_object(Set.new) do |text, stems|
        normalized_words(text).each { |word| (STEM_LENGTH..word.length).each { |size| stems << word.first(size) } }
      end
    end

    # The digit runs of the given texts, for the known-numbers list.
    def numbers(*texts)
      texts.flatten.compact.flat_map { |text| text.to_s.scan(/\d+/) }.uniq
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

  def initialize(text, tool_ids:, allowed:, shingles:, latin_ok:, internal_ids: [], known_numbers: [], agent_names: [], domain_words: Set.new)
    @domain_words = domain_words
    @text = text.to_s
    @tool_ids = Set.new(tool_ids.map(&:to_s))
    @allowed = Set.new((ALLOWED_LATIN + Array(allowed)).map { |word| word.to_s.downcase })
    @shingles = shingles
    @latin_ok = latin_ok
    @internal_ids = Set.new(Array(internal_ids).filter_map { |id| Integer(id, exception: false) })
    @known_numbers = Set.new(Array(known_numbers).map(&:to_s))
    @agent_names = Array(agent_names).map { |name| name.to_s.squish }.reject(&:empty?)
  end

  def findings
    return [] if @text.strip.empty?

    found = Hash.new { |hash, kind| hash[kind] = [] }
    found[:reserved_token].concat(scan(RESERVED_TOKEN))
    found[:identifier].concat(scan(IDENTIFIER) + numbered_records + internal_id_numbers)
    found[:json].concat(scan(JSON_LIKE))
    snake_case(found)
    latin_words_in_text.each { |word| (@tool_ids.include?(word.downcase) ? found[:tool_name] : found[:latin]) << word }
    found[:instruction_overlap].concat(overlap)
    found[:third_person].concat(scan(THIRD_PERSON))
    found[:role_fragment].concat(scan(ROLE_FRAGMENT) + scan(NAME_QUESTION_FRAGMENT))
    found[:stock_text].concat(Captain::Evals::RoutingBenchmark::StockText.found(@text))
    found[:composer_phrase].concat(composer_phrases(found[:stock_text]))
    found[:agent_name].concat(agent_names_in_text)
    found[:tool_error].concat(scan(TOOL_ERROR))
    KINDS.filter_map { |kind| { kind: kind, matches: found[kind].uniq.first(5) } if found[kind].any? }
  end

  private

  def scan(pattern)
    @text.to_enum(:scan, pattern).map { Regexp.last_match(0).strip }
  end

  # The canned council wording that is not also a stock sentence: a stock sentence is the stricter finding.
  def composer_phrases(stock)
    COMPOSER_PHRASES.flat_map { |pattern| scan(pattern) }.reject { |phrase| stock.any? { |line| line.include?(phrase.squish) } }
  end

  # «Запись к врачу», "Диагностика", агент Запись к врачу: the name of an agent used as a name. Written plainly in a sentence it is an
  # ordinary phrase ("запись к врачу на среду") and no finding.
  def agent_names_in_text
    @agent_names.flat_map do |name|
      words = Regexp.escape(name).gsub('\ ') { '\s+' }
      scan(/[«"“„'‘]\s*#{words}\s*[»"”“'’]|агент\p{L}*\s+[«"“]?#{words}[»"”]?/i)
    end
  end

  # "Запись №4821 создана", "Номер вашей записи: 4821", "№ 305": a number sign with three digits or more, or the number of a
  # booking, is a database id unless the customer or the workspace wrote that number themselves.
  def numbered_records
    signed = @text.to_enum(:scan, NUMBER_SIGN).filter_map do
      match = Regexp.last_match
      match[0].strip if @known_numbers.exclude?(match[0][/\d+/])
    end
    signed + scan(RECORD_NUMBER)
  end

  # A standalone number that is the id of a record the turn handled (3 digits or more: a shorter number is too often a
  # day, an hour or a cabinet to tell from an id; "#7" and "id 7" are found by IDENTIFIER). Numbers the customer or the
  # workspace wrote are never ids.
  def internal_id_numbers
    return [] if @internal_ids.empty?

    @text.scan(STANDALONE_NUMBER).filter_map do |number|
      number if number.length >= MIN_ID_DIGITS && @internal_ids.include?(number.to_i) && @known_numbers.exclude?(number)
    end
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
      joined if @shingles.include?(joined) && !topic_run?(run)
    end
  end

  # A run whose content words are all words of the dialogue's own topic says what the patient asked about.
  def topic_run?(run)
    content = run.select { |word| word.length >= CONTENT_WORD_LENGTH }
    content.any? && content.all? { |word| @domain_words.include?(word.first([word.length - 2, STEM_LENGTH].max)) }
  end
end
