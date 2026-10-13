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
  # "Запрос обработан" opens the fixed fallback sentence whatever follows it.
  REQUEST_PROCESSED = /Запрос\s+обработан\.?|Сұрау\s+өңделді\.?/i
  PLACEHOLDER = /%\{\w+\}/

  class << self
    # [Regexp] one per sentence, longest first, so a sentence is cut out whole.
    def patterns
      @patterns ||= sentences.map { |sentence| pattern_for(sentence) }.push(REQUEST_PROCESSED).uniq
    end

    # The stock sentences found in the text, as written there. A match inside a longer one ("Запрос обработан." inside the whole fixed
    # sentence) is the same sentence and is listed once.
    def found(text)
      matches = patterns.flat_map { |pattern| text.to_s.scan(pattern).map { |match| match.is_a?(Array) ? match.first : match } }.map(&:squish).uniq
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
      Dir.glob(Rails.root.join(LOCALE_GLOB)).flat_map do |path|
        data = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
        data.to_h.values.flat_map { |locale| locale.to_h.dig('captain', 'coordination').to_h.values.grep(String) }
      rescue Psych::Exception, SystemCallError
        []
      end
    end

    # "Часть обращения осталась без ответа, нужен ответ сотрудника: %{parts}." -> the same with ".+?" in the gap.
    def pattern_for(sentence)
      parts = sentence.split(PLACEHOLDER, -1).map { |part| Regexp.escape(part).gsub('\ ') { '\s+' } }
      Regexp.new(parts.join('.+?'), Regexp::IGNORECASE)
    end
  end
end
