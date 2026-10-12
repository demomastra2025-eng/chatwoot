# frozen_string_literal: true

# Reads the time, the date and the doctor that a sentence of a reply states, to compare them with the appointment row
# that the same turn wrote. The scorer applies it only to the sentences that claim a booking or a move, so opening
# hours or other offered slots in other sentences never count.
#
#   times   "10:00", "в 10 часов", KK "сағат 12-де"          -> [hour, minute]
#   dates   "15 октября", "15 қазанда", "15.10", "15.10.2026" -> [day, month]
#   stems   a surname stem of a doctor that the sentence names
class Captain::Evals::RoutingBenchmark::ReplyFacts
  MONTH_STEMS = {
    'январ' => 1, 'феврал' => 2, 'март' => 3, 'апрел' => 4, 'мая' => 5, 'май' => 5, 'июн' => 6, 'июл' => 7, 'август' => 8,
    'сентябр' => 9, 'октябр' => 10, 'ноябр' => 11, 'декабр' => 12,
    'қаңтар' => 1, 'ақпан' => 2, 'наурыз' => 3, 'сәуір' => 4, 'мамыр' => 5, 'маусым' => 6, 'шілде' => 7, 'тамыз' => 8,
    'қыркүйек' => 9, 'қазан' => 10, 'қараша' => 11, 'желтоқсан' => 12
  }.freeze
  CLOCK = /(?<![\d:.])([01]?\d|2[0-3]):([0-5]\d)(?![\d:])/
  HOURS_RU = /(?<![\d:.])([01]?\d|2[0-3])\s*(?:час(?:а|ов)?|ч)(?![\p{L}\d])/i
  HOURS_KK = /сағат\s+([01]?\d|2[0-3])(?![\d:])/i
  WORD_DATE = /(?<![\d.])(\d{1,2})\s+(\p{L}+)/
  # The month has two digits ("15.10"), so a decimal such as "1.5 часа" is not a date.
  NUMERIC_DATE = /(?<![\d.:])(\d{1,2})\.(0[1-9]|1[0-2])(?:\.\d{2,4})?(?![\d:])/
  SURNAME_MIN = 4

  class << self
    def times(text)
      text = text.to_s
      found = text.scan(CLOCK).map { |hour, minute| [hour.to_i, minute.to_i] }
      found += text.scan(HOURS_RU).map { |(hour)| [hour.to_i, 0] }
      found += text.scan(HOURS_KK).map { |(hour)| [hour.to_i, 0] }
      found.uniq
    end

    def dates(text)
      text = text.to_s
      found = text.scan(WORD_DATE).filter_map do |day, word|
        month = month_for(word)
        [day.to_i, month] if month
      end
      found += text.scan(NUMERIC_DATE).filter_map do |day, month|
        [day.to_i, month.to_i] if day.to_i.between?(1, 31)
      end
      found.uniq
    end

    # The surname of a resource name: the first capitalised word of four letters or more after the first word, provided
    # a second such word follows ("Терапевт Абдрахманова Сауле" -> "абдрахманова"; "Гинеколог Ким Елена" has none,
    # because a lone name could be a first name that patients share).
    def surname(name)
      words = name.to_s.scan(/\p{L}+/)
      candidates = words.drop(1).select { |word| word.match?(/\A\p{Lu}\p{Ll}+\z/) && word.length >= SURNAME_MIN }
      candidates.first.downcase.tr('ё', 'е') if candidates.size >= 2
    end

    # True when the sentence contains a word that starts with the surname stem.
    def names_surname?(sentence, surname)
      stem = surname.first([surname.length - 2, SURNAME_MIN].max)
      sentence.to_s.downcase.tr('ё', 'е').scan(/\p{L}+/).any? { |word| word.start_with?(stem) }
    end

    private

    def month_for(word)
      lower = word.downcase
      MONTH_STEMS.find { |stem, _month| lower.start_with?(stem) }&.last
    end
  end
end
