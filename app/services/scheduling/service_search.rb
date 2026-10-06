class Scheduling::ServiceSearch
  MIN_TOKEN_LENGTH = 2
  # to_tsvector refuses texts above 1 MB, so only the head of the searchable text is stemmed.
  FTS_TEXT_LIMIT = 20_000
  # The equal-name test reads at most this many rows (shortest names first); it only bounds the work, never the words.
  EXACT_CANDIDATE_LIMIT = 500
  SEARCH_TEXT = 'search_text'.freeze
  SEARCH_VECTOR = 'search_vector'.freeze
  # Prepositions and conjunctions never decide which service is meant ("УЗИ для беременных" = "УЗИ беременных") when a
  # service is looked up. They do decide whether a service is the equal match, see #exact_name_count.
  STOP_WORDS = %w[для при про или как что это из на по со].freeze
  # Small words that change the meaning of a name: "без контраста" is the opposite of "с контрастом" and "до операции"
  # of "после операции". They stay in the query as required words, matched as whole words only because "до" or "от"
  # also sit inside almost any other word. The Russian dictionary drops them as stop words, so no stemming is used.
  WHOLE_WORDS = %w[без до от].freeze
  # A letter, as a range of code points: it does not depend on the locale of the database.
  NOT_LETTER = '[^а-яa-z0-9]'.freeze
  TOKEN_ALIASES = {
    /\Aмрт\z/i => ['мрт', 'магнитно резонансная томография'],
    /\Aузи\z/i => ['узи', 'ультразвуковое исследование'],
    /\Aше(я|и)\z|\Aшей/i => %w[шея шеи шей]
  }.freeze

  attr_reader :match_kind

  def initialize(scope:, query:)
    @scope = scope
    @query = query.to_s
  end

  def call
    @call ||= build_relation
  end

  # How many of the found services have a name, or an alias, with exactly the words of the query. Only such a service may
  # be presented as the one confident match. A word missing on either side, a qualifier that sits only in the
  # description or in the category, a different number or letter code, a cut-off request: none of that is an equal name.
  def exact_name_count
    return 0 if normalized_query.blank? || exact_ids.empty?

    call.reorder(nil).where(id: exact_ids).count
  end

  # True when so many services share the words of the query that the equal-name test could not read them all, so that
  # uniqueness of the equal name is not proven.
  def exact_name_truncated?
    exact_ids
    @exact_truncated
  end

  private

  attr_reader :scope, :query

  def build_relation
    if normalized_query.blank?
      @match_kind = 'listing'
      return scope.order(:name, :id)
    end

    strict_scope = indexed_scope.where(all_concepts_condition)
    @match_kind = strict_scope.exists? ? 'all_concepts' : 'partial'
    return strict_scope.order(Arel.sql(rank_sql), :name, :id) if @match_kind == 'all_concepts'

    partial_scope = indexed_scope.where(broad_condition)
    concepts.blank? ? partial_scope.order(:name, :id) : partial_scope.order(Arel.sql(partial_rank_sql), :name, :id)
  end

  def normalized_query
    @normalized_query ||= Scheduling::SearchText.normalize(query)
  end

  def name_sql
    @name_sql ||= Scheduling::SearchText.fold_sql('scheduling_services.name')
  end

  def name_vector_sql
    "to_tsvector('russian', #{name_sql})"
  end

  def aliases_sql
    "COALESCE(scheduling_services.custom_attributes ->> 'aliases', '')"
  end

  def search_text_sql
    @search_text_sql ||= Scheduling::SearchText.fold_sql(<<~SQL.squish)
      CONCAT_WS(' ', scheduling_services.name, scheduling_services.category, scheduling_services.direction,
                scheduling_services.description, #{aliases_sql})
    SQL
  end

  # The searchable text and its stemmed vector are computed once per row inside a subquery that PostgreSQL may not
  # flatten (OFFSET 0). Without it the same text is stemmed again for every condition of the query, which is the
  # expensive part of a multi-word search.
  def indexed_scope
    @indexed_scope ||= Scheduling::Service.from(scope.select(Arel.sql(indexed_columns_sql)).offset(0), :scheduling_services)
  end

  def indexed_columns_sql
    "scheduling_services.*, #{search_text_sql} AS #{SEARCH_TEXT}, " \
      "to_tsvector('russian', LEFT(#{search_text_sql}, #{FTS_TEXT_LIMIT})) AS #{SEARCH_VECTOR}"
  end

  def concepts
    @concepts ||= begin
      words = Scheduling::SearchText.tokens(normalized_query).select { |token| token.length >= MIN_TOKEN_LENGTH }
      words = (words - STOP_WORDS).presence || words
      words.map { |word| aliases_for(word).uniq }
    end
  end

  def aliases_for(token)
    TOKEN_ALIASES.find { |pattern, _values| token.match?(pattern) }&.last || [token]
  end

  def broad_condition
    return phrase_condition(SEARCH_TEXT) if concepts.blank?

    alternatives_condition(concepts.flatten, SEARCH_TEXT, SEARCH_VECTOR)
  end

  def all_concepts_condition(text_sql = SEARCH_TEXT, vector_sql = SEARCH_VECTOR)
    return phrase_condition(text_sql) if concepts.blank?

    concepts.map { |alternatives| alternatives_condition(alternatives, text_sql, vector_sql) }.join(' AND ')
  end

  # Orders the strict matches: equal name, the phrase in the name, all concepts in the name, anything else.
  def rank_sql
    <<~SQL.squish
      CASE
        WHEN #{exact_rank_condition} THEN 0
        WHEN #{phrase_condition(name_sql)} THEN 1
        WHEN #{all_concepts_condition(name_sql, name_vector_sql)} THEN 2
        ELSE 3
      END
    SQL
  end

  def exact_rank_condition
    return exact_name_condition if exact_ids.empty?

    "(#{exact_name_condition} OR scheduling_services.id IN (#{exact_ids.join(', ')}))"
  end

  # Orders the partial fallback: the more query concepts a service covers, the higher it is.
  def partial_rank_sql
    covered = concepts.map do |alternatives|
      "CASE WHEN #{alternatives_condition(alternatives, SEARCH_TEXT, SEARCH_VECTOR)} THEN 1 ELSE 0 END"
    end
    "(#{covered.join(' + ')}) DESC"
  end

  # The alternatives of one concept match as a substring or, through the Russian dictionary, as another form of the
  # same word.
  def alternatives_condition(alternatives, text_sql, vector_sql)
    connection = scope.connection
    return whole_word_condition(alternatives.first, text_sql) if alternatives.size == 1 && WHOLE_WORDS.include?(alternatives.first)

    patterns = alternatives.map { |value| "#{text_sql} ILIKE #{connection.quote("%#{escaped(value)}%")}" }
    tsquery = alternatives.map { |value| "plainto_tsquery('russian', #{connection.quote(value)})" }.join(' || ')
    "(#{patterns.join(' OR ')} OR #{vector_sql} @@ (#{tsquery}))"
  end

  def whole_word_condition(word, text_sql)
    "#{text_sql} ~* #{scope.connection.quote("(^|#{NOT_LETTER})#{word}(#{NOT_LETTER}|$)")}"
  end

  def exact_name_condition
    "#{name_sql} = #{scope.connection.quote(normalized_query)}"
  end

  def phrase_condition(text_sql)
    "#{text_sql} ILIKE #{scope.connection.quote("%#{escaped(normalized_query)}%")}"
  end

  # The ids of the services of the scope whose name or alias has exactly the words of the query. The database only
  # narrows the candidates (every query word, as its stem, occurs in the name or the aliases, shortest names first); the
  # words are then compared in Ruby, all of them and without a stop list.
  def exact_ids
    @exact_ids ||= begin
      @exact_truncated = false
      searchable = normalized_query.present? && !Scheduling::SearchText.truncated?(query)
      (searchable ? equal_name_ids : []).freeze
    end
  end

  def equal_name_ids
    rows = exact_candidate_rows.to_a
    @exact_truncated = rows.size > EXACT_CANDIDATE_LIMIT
    rows.first(EXACT_CANDIDATE_LIMIT).filter_map do |id, name, aliases|
      id if equal_text?(name) || alias_texts(aliases).any? { |text| equal_text?(text) }
    end
  end

  def exact_candidate_rows
    scope.where(exact_prefilter_condition)
         .reorder(Arel.sql('char_length(scheduling_services.name)'), :id)
         .limit(EXACT_CANDIDATE_LIMIT + 1)
         .pluck(:id, :name, Arel.sql("scheduling_services.custom_attributes -> 'aliases'"))
  end

  def exact_prefilter_condition
    haystack = Scheduling::SearchText.fold_sql("CONCAT_WS(' ', scheduling_services.name, #{aliases_sql})")
    fragments = Scheduling::SearchText.words(normalized_query).flat_map { |word| word_fragments(word) }.uniq
    return exact_name_condition if fragments.empty?

    fragments.map { |fragment| "#{haystack} ILIKE #{scope.connection.quote("%#{escaped(fragment)}%")}" }.join(' AND ')
  end

  # A decimal number is found as its two parts (the stored text may hold "1,5" for "1.5"); a word as its stem.
  def word_fragments(word)
    word.include?('.') ? word.split('.') : [Scheduling::SearchText.stem(word)]
  end

  def equal_text?(text)
    Scheduling::SearchText.same_words?(normalized_query, Scheduling::SearchText.normalize(text, max_length: nil))
  end

  def alias_texts(aliases)
    Array(aliases).flat_map { |value| value.to_s.split("\n") }.compact_blank
  end

  def escaped(value)
    ActiveRecord::Base.sanitize_sql_like(value.to_s.downcase)
  end
end
