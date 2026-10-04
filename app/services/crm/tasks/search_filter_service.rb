class Crm::Tasks::SearchFilterService
  SEARCH_SQL = <<~SQL.squish.freeze
    CAST(crm_tasks.id AS TEXT) ILIKE :query OR
    crm_tasks.title ILIKE :query OR
    crm_tasks.description ILIKE :query OR
    crm_tasks.external_ref ILIKE :query OR
    crm_tasks.outcome_note ILIKE :query OR
    crm_tasks.activity_type ILIKE :query OR
    crm_tasks.outcome ILIKE :query OR
    search_task_types.name ILIKE :query OR
    crm_task_outcomes.name ILIKE :query OR
    crm_deals.title ILIKE :query OR
    users.name ILIKE :query OR
    users.email ILIKE :query
  SQL

  def initialize(scope:, params:)
    @scope = scope
    @params = params
  end

  def perform
    filter_by_query(scope)
  end

  private

  attr_reader :scope, :params

  def filter_by_query(scope)
    return scope if params[:q].blank?

    raw_query = params[:q].to_s.strip.first(200)
    bindings = custom_field_search_bindings(raw_query).merge(query: search_pattern(raw_query.delete_prefix('#')))
    clauses = [SEARCH_SQL, ::Crm::Tasks::CustomFieldSearchQuery::SQL]
    scope.left_joins(:deal, :assignee, :task_outcome)
         .joins(activity_type_catalog_join)
         .where(clauses.join(' OR '), bindings)
  end

  def activity_type_catalog_join
    Arel.sql(<<~SQL.squish)
      LEFT OUTER JOIN crm_task_types AS search_task_types
        ON search_task_types.account_id = crm_tasks.account_id
        AND (
          search_task_types.id = crm_tasks.task_type_id
          OR (crm_tasks.task_type_id IS NULL AND search_task_types.code = crm_tasks.activity_type)
        )
    SQL
  end

  def custom_field_search_bindings(raw_query)
    date_alias = valid_alias(:q_date_alias, /\A\d{4}-\d{2}-\d{2}\z/)
    datetime_alias = datetime_search_alias
    {
      checked_alias: ActiveModel::Type::Boolean.new.cast(params[:q_checked]),
      date_alias: date_alias,
      date_alias_pattern: "#{date_alias}%",
      datetime_alias: datetime_alias,
      numeric_alias: numeric_search_alias(raw_query).to_s,
      percent_alias: percent_search_alias(raw_query).to_s
    }
  end

  def search_pattern(term)
    "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
  end

  def valid_alias(param_name, pattern)
    value = params[param_name].to_s
    value.match?(pattern) ? value : ''
  end

  def numeric_search_alias(raw_query)
    return if raw_query.include?('%')

    frontend_alias = params[:q_numeric_alias].to_s
    return frontend_alias if frontend_alias.match?(/\A-?\d+(?:\.\d+)?\z/)

    normalized = raw_query.delete(" \u00A0").tr(',', '.')
    normalized if normalized.match?(/\A-?\d+(?:\.\d+)?\z/)
  end

  def datetime_search_alias
    value = params[:q_datetime_alias].to_s
    return '' unless value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}Z\z/)

    Time.iso8601(value.sub(/Z\z/, ':00Z'))
    value
  rescue ArgumentError
    ''
  end

  def percent_search_alias(raw_query)
    normalized = raw_query.delete(" \u00A0").tr(',', '.')
    match = normalized.match(/\A(-?\d+(?:\.\d+)?)%\z/)
    match[1] if match
  end
end
