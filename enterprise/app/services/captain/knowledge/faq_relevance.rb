# A short question can have a low cosine score against an embedding of a whole
# FAQ question and answer. Rescue only its leading native candidate when the
# question independently corroborates every meaningful query term.
class Captain::Knowledge::FaqRelevance
  MINIMUM_SIMILARITY = 0.4
  MINIMUM_QUESTION_COVERAGE = 1.0 / 3
  MINIMUM_MARGIN = 0.08
  MAX_QUERY_TERMS = 12
  MAX_QUESTION_TERMS = 32
  MAX_TERM_LENGTH = 48
  MINIMUM_INFLECTION_STEM_LENGTH = 5
  INFLECTION_SUFFIXES = {
    # Plural forms preserve the noun. Verb endings can change the topic, such
    # as an account versus accounting, and need independent semantic evidence.
    latin: [''] + %w[s es],
    cyrillic: [''] + %w[а я у ю е и ы о й ь ом ем ой ей ам ям ах ях ов ев ию ия ии
                       ый ий ая ое ые ого ому ыми ге ке га ка ға қа де да те та ді ды ті ты
                       ның нің дың дің тың тің лар лер нан нен дан ден тан тен мен бен пен]
  }.transform_values(&:freeze).freeze
  STOP_WORDS = %w[
    a an the to for of i me my we can could would want need please is are do does how what
    я мне мой мы хочу хотел нужно нужен нужна пожалуйста можно как что такое на к у в по для ли с это вы вас могу
  ].freeze

  def self.select(candidates, query:, translated_query: nil)
    new(candidates, [query, translated_query].compact.uniq).select
  end

  def initialize(candidates, queries)
    @candidates = candidates.sort_by { |candidate| -similarity(candidate) }
    @queries = queries
  end

  def select
    leader = @candidates.first
    return rejected('no_candidates') unless leader
    return rejected('below_semantic_floor') if similarity(leader) < MINIMUM_SIMILARITY

    checks = queries_for(leader).map { |query| corroboration(query, leader) }
    evidence = checks.find { |check| check[:passed] } || checks.max_by { |check| check[:query_coverage].to_f }
    return rejected('question_not_corroborated', evidence) unless evidence[:passed]

    rivals = @candidates.drop(1).select do |candidate|
      queries_for(candidate).any? { |query| corroboration(query, candidate)[:passed] }
    end
    margin = rivals.empty? ? nil : (similarity(leader) - rivals.map { |candidate| similarity(candidate) }.max).round(6)
    return rejected('ambiguous_question_matches', evidence.merge(margin: margin)) if margin && margin < MINIMUM_MARGIN

    { response: leader, check: base_check.merge(evidence).merge(passed: true, response_id: leader.id, margin: margin&.round(6)).compact }
  end

  private

  def corroboration(query, candidate)
    query_terms = terms(query)
    question_terms = terms(candidate.question)
    return { passed: false, query_coverage: 0.0 } if query_terms.empty? || query_terms.size > MAX_QUERY_TERMS || question_terms.empty?
    return { passed: false, query_coverage: 0.0 } if question_terms.size > MAX_QUESTION_TERMS
    return { passed: false, query_coverage: 0.0 } if query_terms.any? { |term| term.length > MAX_TERM_LENGTH }

    matches = query_terms.filter_map do |term|
      exact = question_terms.find { |word| word == term }
      inflection = question_terms.find { |word| inflection_equivalent?(term, word) } unless exact
      word = exact || inflection || question_terms.find { |item| typo_equivalent?(term, item) }
      next unless word
      # Inflected forms carry the same evidence on both sides of the ambiguity
      # check. Only a genuine typo guess loses to an exact competing word.
      next if !exact && !inflection && @candidates.any? { |other| other != candidate && terms(other.question).include?(term) }

      word
    end
    query_coverage = matches.size.to_f / query_terms.size
    question_coverage = matches.uniq.size.to_f / question_terms.size
    specific_query = query_terms.size > 1 || query_terms.first.length >= 5
    { passed: specific_query && matches.size == query_terms.size && question_coverage >= MINIMUM_QUESTION_COVERAGE,
      query_coverage: query_coverage.round(6), question_coverage: question_coverage.round(6) }
  end

  def terms(text)
    text.to_s.downcase.tr('ё', 'е').scan(/[\p{Alnum}]+/).reject { |word| STOP_WORDS.include?(word) }.uniq
  end

  def queries_for(candidate)
    original = @queries.first.to_s
    question = candidate.question.to_s
    same_script = (original.match?(/\p{Cyrillic}/) && question.match?(/\p{Cyrillic}/)) ||
                  (!original.match?(/\p{Cyrillic}/) && original.match?(/\p{Latin}/) && question.match?(/\p{Latin}/))
    same_script ? [original] : @queries
  end

  def inflection_equivalent?(left, right)
    suffixes = if left.match?(/\A\p{Latin}+\z/) && right.match?(/\A\p{Latin}+\z/)
                 INFLECTION_SUFFIXES[:latin]
               elsif left.match?(/\A\p{Cyrillic}+\z/) && right.match?(/\A\p{Cyrillic}+\z/)
                 INFLECTION_SUFFIXES[:cyrillic]
               end
    return false unless suffixes && [left.length, right.length].max <= MAX_TERM_LENGTH

    prefix = left.chars.zip(right.chars).take_while { |a, b| a == b }.size
    prefix.downto(MINIMUM_INFLECTION_STEM_LENGTH).any? do |length|
      suffixes.include?(left[length..]) && suffixes.include?(right[length..])
    end
  end

  def typo_equivalent?(left, right)
    return false unless left.match?(/\A\p{L}{5,}\z/) && right.match?(/\A\p{L}{5,}\z/)
    return false if [left.length, right.length].max > MAX_TERM_LENGTH
    return false if (left.length - right.length).abs > 1

    edit_distance(left, right) <= 1
  end

  # One insertion/deletion/substitution or adjacent transposition, without
  # matching short words, numbers, or arbitrary shared substrings.
  def edit_distance(left, right)
    previous_previous = nil
    previous = (0..right.length).to_a
    left.chars.each_with_index do |character, index|
      current = [index + 1]
      right.chars.each_with_index do |other, column|
        current << [current[column] + 1, previous[column + 1] + 1, previous[column] + (character == other ? 0 : 1)].min
        next unless index.positive? && column.positive? && character == right[column - 1] && left[index - 1] == other

        current[column + 1] = [current[column + 1], previous_previous[column - 1] + 1].min
      end
      previous_previous, previous = previous, current
    end
    previous.last
  end

  def similarity(candidate)
    distance = candidate.respond_to?(:neighbor_distance) ? candidate.neighbor_distance : nil
    return -1.0 unless distance.present?

    score = 1.0 - distance.to_f
    score.finite? ? score.round(6) : -1.0
  end

  def base_check
    { metric: 'question_terms_and_cosine_margin', minimum_similarity: MINIMUM_SIMILARITY,
      minimum_query_coverage: 1.0, minimum_question_coverage: MINIMUM_QUESTION_COVERAGE.round(6), minimum_margin: MINIMUM_MARGIN }
  end

  def rejected(reason, evidence = {})
    { response: nil, check: base_check.merge(evidence).merge(passed: false, reason: reason) }
  end
end
