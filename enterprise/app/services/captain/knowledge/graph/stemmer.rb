# frozen_string_literal: true

class Captain::Knowledge::Graph::Stemmer
  MIN_STEM_LENGTH = 3
  MIN_TRIM_STEM_LENGTH = 4
  STOP_WORDS = (
    Captain::Knowledge::FaqRelevance::STOP_WORDS + %w[
      какие какой какая какое каких сколько когда где кто чем при без или для как что есть ли нужны нужно нужна
      стоит цена цены прием приём записаться запись принимает ведут ведет врач врачи доктор клинике клиника
      год года лет день дни час часа часов тенге тг kzt
      қандай қанша қашан қайда кім неге бар ма ба па пе ме бе үшін мен бен пен керек болады дәрігер бағасы
    ]
  ).uniq.freeze

  SYNONYM_MAP = {
    'лор' => %w[лор отоларинголог оториноларинголог],
    'отоларинголог' => %w[лор отоларинголог],
    'оториноларинголог' => %w[лор отоларинголог],
    'фгдс' => %w[фгдс гастроскоп эндоскоп],
    'гастроскоп' => %w[фгдс гастроскоп эндоскоп],
    'эндоскоп' => %w[фгдс гастроскоп эндоскоп],
    'невролог' => %w[невролог невропатолог],
    'невропатолог' => %w[невролог невропатолог],
    'обп' => %w[обп брюшн],
    'экг' => %w[экг электрокардиограф],
    'ээг' => %w[ээг электроэнцефалограф],
    'эхокг' => %w[эхокг эхокардиограф сердц],
    'уздг' => %w[уздг допплер сосуд],
    'воп' => %w[воп терапевт общ практик]
  }.freeze

  CYRILLIC_SUFFIXES = Captain::Knowledge::FaqRelevance::INFLECTION_SUFFIXES[:cyrillic]
                      .reject(&:empty?)
                      .sort_by { |s| -s.length }
                      .freeze
  LATIN_SUFFIXES = Captain::Knowledge::FaqRelevance::INFLECTION_SUFFIXES[:latin]
                   .reject(&:empty?)
                   .sort_by { |s| -s.length }
                   .freeze

  class << self
    def normalize_key(text)
      text.to_s.downcase.tr('ё', 'е').gsub(/[^\p{Alnum}]+/, '_').gsub(/\A_|_\z/, '')
    end

    def extract_stems(*texts, include_synonyms: true)
      tokens = texts.flatten.compact.join(' ').downcase.tr('ё', 'е').scan(/[\p{Alnum}]+/)
      meaningful = tokens.reject { |token| STOP_WORDS.include?(token) || token.length < MIN_STEM_LENGTH }
      raw_stems = meaningful.flat_map { |token| [token, stem_token(token), consonant_root(stem_token(token))] }.uniq
      return raw_stems unless include_synonyms

      expanded = raw_stems.flat_map { |stem| [stem] + Array(SYNONYM_MAP[stem]) }
      expanded.uniq
    end

    def stem_token(token)
      return token if token.length <= MIN_TRIM_STEM_LENGTH

      suffixes = if token.match?(/\A\p{Cyrillic}+\z/)
                   CYRILLIC_SUFFIXES
                 elsif token.match?(/\A\p{Latin}+\z/)
                   LATIN_SUFFIXES
                 else
                   []
                 end

      suffixes.each do |suffix|
        next unless token.end_with?(suffix)

        candidate = token[0...-suffix.length]
        return candidate if candidate.length >= MIN_TRIM_STEM_LENGTH
      end

      token
    end

    def consonant_root(stem)
      return stem unless stem.match?(/\A\p{Cyrillic}+\z/) && stem.length > MIN_TRIM_STEM_LENGTH

      trimmed = stem.sub(/[аяуюеиыоэ]+\z/, '')
      trimmed.length >= MIN_TRIM_STEM_LENGTH ? trimmed : stem
    end
  end
end
