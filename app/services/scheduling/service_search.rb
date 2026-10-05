class Scheduling::ServiceSearch
  MAX_TOKENS = 8
  MIN_TOKEN_LENGTH = 2
  TOKEN_ALIASES = {
    /\Aмрт\z/i => ['мрт', 'магнитно резонансная томография'],
    /\Aузи\z/i => ['узи', 'ультразвуковое исследование'],
    /\Aше(я|и)\z|\Aшей/i => %w[шея шеи шей]
  }.freeze

  def initialize(scope:, query:)
    @scope = scope
    @query = query.to_s
  end

  def call
    return scope if normalized_query.blank?

    strict_scope = scope.where(all_concepts_condition)
    @match_kind = strict_scope.exists? ? 'all_concepts' : 'partial'
    matching_scope = @match_kind == 'all_concepts' ? strict_scope : scope.where(broad_condition)
    matching_scope.order(Arel.sql(rank_sql), :name, :id)
  end

  attr_reader :match_kind

  private

  attr_reader :scope, :query

  def normalized_query
    @normalized_query ||= query.downcase.squish
  end

  def search_text_sql
    <<~SQL.squish
      LOWER(CONCAT_WS(' ', name, category, direction, description, COALESCE(custom_attributes ->> 'aliases', '')))
    SQL
  end

  def concepts
    tokens = normalized_query.scan(/[[:alnum:]]+/).first(MAX_TOKENS)
    @concepts ||= tokens.select { |token| token.length >= MIN_TOKEN_LENGTH }.map do |token|
      aliases_for(token).map { |value| "%#{escaped(value)}%" }.uniq
    end
  end

  def aliases_for(token)
    TOKEN_ALIASES.find { |pattern, _values| token.match?(pattern) }&.last || [token]
  end

  def broad_condition
    return phrase_condition(search_text_sql) if concepts.blank?

    "(#{concepts.flatten.map { |value| concept_condition(search_text_sql, value) }.join(' OR ')})"
  end

  def all_concepts_condition(text_sql = search_text_sql)
    return phrase_condition(text_sql) if concepts.blank?

    concepts.map do |alternatives|
      "(#{alternatives.map { |value| concept_condition(text_sql, value) }.join(' OR ')})"
    end.join(' AND ')
  end

  def rank_sql
    <<~SQL.squish
      CASE
        WHEN LOWER(name) = #{scope.connection.quote(normalized_query)} THEN 0
        WHEN #{all_concepts_condition('LOWER(name)')} THEN 1
        WHEN #{phrase_condition('LOWER(name)')} THEN 2
        WHEN #{all_concepts_condition} THEN 3
        ELSE 4
      END
    SQL
  end

  def phrase_condition(text_sql)
    pattern = scope.connection.quote("%#{escaped(normalized_query)}%")
    "#{text_sql} ILIKE #{pattern}"
  end

  def concept_condition(text_sql, value)
    phrase = scope.connection.quote("%#{escaped(value)}%")
    lexeme = scope.connection.quote(value)
    "(#{text_sql} ILIKE #{phrase} OR to_tsvector('russian', #{text_sql}) @@ plainto_tsquery('russian', #{lexeme}))"
  end

  def escaped(value)
    ActiveRecord::Base.sanitize_sql_like(value.to_s.downcase)
  end
end
