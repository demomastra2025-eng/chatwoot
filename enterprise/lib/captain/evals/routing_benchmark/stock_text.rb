# frozen_string_literal: true

# The runtime's own sentences that can reach a patient instead of a reply written by an agent: the `captain.coordination.*`
# texts of the locale files ("Действие выполнено.", "Запрос отменён.", "По этому вопросу вам ответит сотрудник клиники.",
# "Запрос обработан. Если нужны подробности ...") and their Kazakh versions. The owner's rule is that no hardcoded text is shown to
# a patient; the runtime drops these sentences, and the benchmark treats every one of them as an internal-text leak (gate item e).
#
# The sentences are read from the locale files of the checkout under test, in every locale found, and a built-in list keeps the
# check alive when the runtime deletes a key. A sentence with an interpolation (%{parts}) matches whatever fills the gap.
# The scorer removes these sentences before it looks for claims: a stock "Запрос отменён." is a leak, but it is not the
# agent's claim that something was cancelled.
module Captain::Evals::RoutingBenchmark::StockText
  LOCALE_GLOB = 'config/locales/captain_coordination.*.yml'
  # Texts the runtime has shown to patients, whatever the locale files hold today.
  BUILTIN = [
    'По этому вопросу вам ответит сотрудник клиники.', 'Бұл сұрақ бойынша сізге клиника қызметкері жауап береді.',
    'Действие выполнено.', 'Әрекет орындалды.',
    'Запрос отменён.', 'Сұрау тоқтатылды.',
    'Запрос обработан. Если нужны подробности, уточните, пожалуйста, вопрос.', 'Сұрау өңделді. Толығырақ білу үшін сұрағыңызды нақтылаңыз.',
    'На этот вопрос я сейчас не могу ответить.', 'Бұл сұраққа қазір жауап бере алмаймын.',
    'Запрос отправлен, подтверждение придёт сообщением.', 'Сұрау жіберілді, растау хабарлама арқылы келеді.'
  ].freeze
  # The opening of the fixed fallback sentence, at the start of a sentence and in this case: "Запрос обработан. Если нужны подробности ...".
  # An agent's own "Ваш запрос обработан, менеджер свяжется с вами." is no fallback, and the runtime marks the real one with
  # response['tool_result_fallback'] as well.
  REQUEST_PROCESSED = /(?<![\p{L}\p{N},;]\s)(?<![\p{L}\p{N},;])(?:Запрос\s+обработан\.\s+Если\s+нужны\s+подробности|Сұрау\s+өңделді\.\s+Толығырақ)/
  PLACEHOLDER = /%\{\w+\}/
  # A locale value with a placeholder is a stock sentence only when it has this many words of its own. "«%{request}»: %{result}" and
  # "Остаётся открытым: %{parts}." are templates of a report for staff: as patterns they would match any quoted name followed by a colon.
  MIN_FIXED_WORDS = 3

  class << self
    # [Regexp] one per sentence, longest first, so a sentence is cut out whole.
    def patterns
      @patterns ||= sentences.map { |sentence| pattern_for(sentence) }.push(REQUEST_PROCESSED).uniq
    end

    # The stock sentences found in the text, as written there, in the order of the text. A match inside a longer one (the opening of the
    # fixed fallback sentence inside the whole sentence) is the same sentence and is listed once.
    def found(text)
      text = text.to_s
      hits = patterns.flat_map { |pattern| text.to_enum(:scan, pattern).map { Regexp.last_match } }
      matches = hits.sort_by { |hit| [hit.begin(0), -hit[0].length] }.map { |hit| hit[0].squish }.uniq
      matches.reject { |match| matches.any? { |other| other != match && other.include?(match) } }
    end

    # The text without its stock sentences.
    def strip(text)
      patterns.inject(text.to_s) { |rest, pattern| rest.gsub(pattern, ' ') }.gsub(/[ \t]{2,}/, ' ').strip
    end

    def reset!
      @patterns = nil
    end

    private

    def sentences
      (BUILTIN + locale_sentences).map { |sentence| sentence.to_s.squish }.reject(&:empty?).uniq.sort_by { |sentence| -sentence.length }
    end

    def locale_sentences
      found = Dir.glob(Rails.root.join(LOCALE_GLOB)).flat_map do |path|
        data = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
        data.to_h.values.flat_map { |locale| locale.to_h.dig('captain', 'coordination').to_h.values.grep(String) }
      rescue Psych::Exception, SystemCallError
        []
      end
      found.select { |sentence| specific?(sentence) }
    end

    # A sentence without a gap matches only itself. One with a gap needs words of its own, or the gap matches an ordinary sentence.
    def specific?(sentence)
      return true unless sentence.match?(PLACEHOLDER)

      sentence.gsub(PLACEHOLDER, ' ').scan(/\p{L}{2,}/).size >= MIN_FIXED_WORDS
    end

    # "Часть обращения осталась без ответа, нужен ответ сотрудника: %{parts}." -> the same with ".+?" in the gap. A gap that ends the
    # sentence stops at the end of the sentence, or the pattern would take one character of it and leave the rest in the text.
    def pattern_for(sentence)
      parts = sentence.split(PLACEHOLDER, -1).map { |part| Regexp.escape(part).gsub('\ ') { '\s+' } }
      source = parts.size > 1 && parts.last.empty? ? "#{parts[0...-1].join('.+?')}[^.!?\\n]+" : parts.join('.+?')
      Regexp.new(source, Regexp::IGNORECASE)
    end
  end
end
