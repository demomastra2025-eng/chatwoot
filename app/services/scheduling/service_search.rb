class Scheduling::ServiceSearch
  MIN_TOKEN_LENGTH = 2
  # to_tsvector refuses texts above 1 MB, so only the head of the searchable text is stemmed.
  FTS_TEXT_LIMIT = 20_000
  SEARCH_TEXT = 'search_text'.freeze
  SEARCH_VECTOR = 'search_vector'.freeze
  # Prepositions and conjunctions never decide which service is meant ("УЗИ для беременных" = "УЗИ беременных").
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

  def exact_name_count
    return 0 if normalized_query.blank?

    scope.where(exact_name_condition).count
  end

  private

  attr_reader :scope, :query

  def normalized_query
    @normalized_query ||= Scheduling::SearchText.normalize(query)
  end

  def name_sql
    @name_sql ||= Scheduling::SearchText.fold_sql('scheduling_services.name')
  end

  def name_vector_sql
    "to_tsvector('russian', #{name_sql})"
  end

  def search_text_sql
    @search_text_sql ||= Scheduling::SearchText.fold_sql(<<~SQL.squish)
      CONCAT_WS(' ', scheduling_services.name, scheduling_services.category, scheduling_services.direction,
                scheduling_services.description, COALESCE(scheduling_services.custom_attributes ->> 'aliases', ''))
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

  # Orders the strict matches: exact name, the phrase in the name, all concepts in the name, anything else.
  def rank_sql
    <<~SQL.squish
      CASE
        WHEN #{exact_name_condition} THEN 0
        WHEN #{phrase_condition(name_sql)} THEN 1
        WHEN #{all_concepts_condition(name_sql, name_vector_sql)} THEN 2
        ELSE 3
      END
    SQL
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

  def escaped(value)
    ActiveRecord::Base.sanitize_sql_like(value.to_s.downcase)
  end
end
