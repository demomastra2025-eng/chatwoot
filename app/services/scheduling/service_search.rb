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
    matching_scope = strict_scope.exists? ? strict_scope : scope.where(broad_condition)
    matching_scope.order(Arel.sql(rank_sql), :name, :id)
  end

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
    return scope.klass.sanitize_sql_array(["#{search_text_sql} ILIKE ?", "%#{escaped(normalized_query)}%"]) if concepts.blank?

    sql = concepts.flatten.map { "#{search_text_sql} ILIKE ?" }.join(' OR ')
    scope.klass.sanitize_sql_array([sql, *concepts.flatten])
  end

  def all_concepts_condition
    return broad_condition if concepts.blank?

    fragments = concepts.map do |alternatives|
      "(#{alternatives.map { "#{search_text_sql} ILIKE ?" }.join(' OR ')})"
    end
    scope.klass.sanitize_sql_array([fragments.join(' AND '), *concepts.flatten])
  end

  def rank_sql
    exact_phrase = scope.klass.sanitize_sql_array(["#{search_text_sql} ILIKE ?", "%#{escaped(normalized_query)}%"])
    <<~SQL.squish
      CASE
        WHEN LOWER(name) = #{scope.connection.quote(normalized_query)} THEN 0
        WHEN #{exact_phrase} THEN 1
        WHEN #{all_concepts_condition} THEN 2
        ELSE 3
      END
    SQL
  end

  def escaped(value)
    ActiveRecord::Base.sanitize_sql_like(value.to_s.downcase)
  end
end
