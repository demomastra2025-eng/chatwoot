class Crm::Tasks::FilterService
  EXACT_FIELDS = %i[
    status_id activity_type task_type_id task_outcome_id outcome assignee_id team_id priority deal_id context_kind
  ].freeze
  SEARCH_SQL = <<~SQL.squish.freeze
    CAST(crm_tasks.id AS TEXT) ILIKE %<query>s OR
    crm_tasks.title ILIKE %<query>s OR
    crm_tasks.description ILIKE %<query>s OR
    crm_tasks.external_ref ILIKE %<query>s OR
    crm_tasks.outcome_note ILIKE %<query>s OR
    crm_tasks.activity_type ILIKE %<query>s OR
    crm_tasks.outcome ILIKE %<query>s OR
    search_task_types.name ILIKE %<query>s OR
    crm_task_outcomes.name ILIKE %<query>s OR
    crm_deals.title ILIKE %<query>s OR
    users.name ILIKE %<query>s OR
    users.email ILIKE %<query>s
  SQL

  def initialize(account:, scope:, params:, custom_attribute_filters:)
    @account = account
    @scope = scope
    @params = params
    @custom_attribute_filters = custom_attribute_filters
  end

  def perform
    filtered_scope = EXACT_FIELDS.reduce(base_scope) { |result, field| filter_by_exact(result, field) }
    filtered_scope = filter_by_due_range(filtered_scope)
    filtered_scope = filter_by_state(filtered_scope)
    filtered_scope = filter_by_query(filtered_scope)
    apply_custom_attribute_filters(filtered_scope)
  end

  private

  attr_reader :account, :params, :custom_attribute_filters

  def base_scope
    archived? ? @scope.archived : @scope.kept
  end

  def archived?
    ActiveModel::Type::Boolean.new.cast(params[:archived])
  end

  def filter_by_exact(scope, field_name)
    return scope if params[field_name].blank?

    scope.where(field_name => params[field_name])
  end

  def filter_by_due_range(scope)
    from = parse_datetime(:due_from)
    to = parse_datetime(:due_to)
    return scope if from.blank? && to.blank?

    scope.where(
      due_range_clause(from: from, to: to),
      from: from,
      to: to,
      from_date: workspace_date(from),
      to_date: workspace_date(to)
    )
  end

  def parse_datetime(field_name)
    value = params[field_name]
    return if value.blank?

    Time.zone.parse(value.to_s) || raise(ArgumentError, "#{field_name} must be a valid datetime")
  end

  def workspace_date(value)
    value&.in_time_zone(account.workspace_working_hours_timezone)&.to_date
  end

  def due_range_clause(from:, to:)
    return bounded_due_range_clause if from.present? && to.present?
    return 'crm_tasks.due_at >= :from OR crm_tasks.due_on >= :from_date' if from.present?

    'crm_tasks.due_at < :to OR crm_tasks.due_on < :to_date'
  end

  def bounded_due_range_clause
    <<~SQL.squish
      (crm_tasks.due_at >= :from AND crm_tasks.due_at < :to) OR
      (crm_tasks.due_on >= :from_date AND crm_tasks.due_on < :to_date)
    SQL
  end

  def filter_by_query(scope)
    return scope if params[:q].blank?

    raw_query = params[:q].to_s.strip.first(200)
    bindings = custom_field_search_bindings(raw_query).merge(query: search_pattern(raw_query.delete_prefix('#')))
    clauses = [format(SEARCH_SQL, query: ':query'), ::Crm::Tasks::CustomFieldSearchQuery::SQL]
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

  def filter_by_state(scope)
    case params[:task_state]
    when 'active'
      scope.where(completed_at: nil, cancelled_at: nil)
    when 'completed'
      scope.where.not(completed_at: nil)
    when 'cancelled'
      scope.where.not(cancelled_at: nil)
    else
      scope
    end
  end

  def apply_custom_attribute_filters(scope)
    ::Crm::CustomFieldFilterSet.new(
      account: account,
      entity_kind: 'task',
      raw_filters: custom_attribute_filters
    ).apply(scope)
  end
end
