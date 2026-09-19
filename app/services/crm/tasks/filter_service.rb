class Crm::Tasks::FilterService
  TIME_BUCKETS = %w[overdue today tomorrow nextWeek thisMonth future unscheduled].freeze
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
    filtered_scope = filter_by_calendar_range(filtered_scope)
    filtered_scope = filter_by_time_bucket(filtered_scope)
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

  def filter_by_calendar_range(scope)
    from = parse_datetime(:calendar_from)
    to = parse_datetime(:calendar_to)
    return scope if from.blank? && to.blank?

    raise ArgumentError, 'calendar_from and calendar_to must be provided together' if from.blank? || to.blank?

    scope.where(
      calendar_overlap_clause,
      from: from,
      to: to,
      from_date: parse_date(:calendar_from_date) || workspace_date(from),
      to_date: parse_date(:calendar_to_date) || workspace_date(to)
    )
  end

  def filter_by_time_bucket(scope)
    bucket = params[:time_bucket].to_s
    return scope if bucket.blank?
    return scope.none unless TIME_BUCKETS.include?(bucket)
    return scope.where(due_at: nil, due_on: nil) if bucket == 'unscheduled'

    boundaries = time_bucket_boundaries
    case bucket
    when 'overdue'
      scope.where(
        'crm_tasks.due_at < :now OR crm_tasks.due_on < :today',
        now: boundaries[:now],
        today: boundaries[:today]
      )
    when 'today'
      due_bucket_scope(scope, boundaries[:now], boundaries[:tomorrow], boundaries[:today], boundaries[:tomorrow_date])
    when 'tomorrow'
      due_bucket_scope(
        scope,
        boundaries[:tomorrow],
        boundaries[:day_after_tomorrow],
        boundaries[:tomorrow_date],
        boundaries[:day_after_tomorrow_date]
      )
    when 'nextWeek'
      due_bucket_scope(
        scope,
        boundaries[:day_after_tomorrow],
        boundaries[:next_week],
        boundaries[:day_after_tomorrow_date],
        boundaries[:next_week_date]
      )
    when 'thisMonth'
      due_bucket_scope(
        scope,
        boundaries[:next_week],
        boundaries[:next_month],
        boundaries[:next_week_date],
        boundaries[:next_month_date]
      )
    when 'future'
      scope.where(
        'crm_tasks.due_at >= :next_month OR crm_tasks.due_on >= :next_month_date',
        next_month: boundaries[:next_month],
        next_month_date: boundaries[:next_month_date]
      )
    end
  end

  def due_bucket_scope(scope, from, to, from_date, to_date)
    scope.where(
      <<~SQL.squish,
        (crm_tasks.due_at >= :from AND crm_tasks.due_at < :to) OR
        (crm_tasks.due_on >= :from_date AND crm_tasks.due_on < :to_date)
      SQL
      from: from,
      to: to,
      from_date: from_date,
      to_date: to_date
    )
  end

  def time_bucket_boundaries
    timezone = account.workspace_working_hours_timezone
    now = (parse_datetime(:as_of) || Time.current).in_time_zone(timezone)
    today = now.to_date
    tomorrow_date = today + 1.day
    day_after_tomorrow_date = today + 2.days
    next_week_date = today + 8.days
    next_month_date = today.advance(months: 1)

    {
      now: now,
      today: today,
      tomorrow: tomorrow_date.in_time_zone(timezone),
      tomorrow_date: tomorrow_date,
      day_after_tomorrow: day_after_tomorrow_date.in_time_zone(timezone),
      day_after_tomorrow_date: day_after_tomorrow_date,
      next_week: next_week_date.in_time_zone(timezone),
      next_week_date: next_week_date,
      next_month: next_month_date.in_time_zone(timezone),
      next_month_date: next_month_date
    }
  end

  def parse_datetime(field_name)
    value = params[field_name]
    return if value.blank?

    Time.zone.parse(value.to_s) || raise(ArgumentError, "#{field_name} must be a valid datetime")
  end

  def parse_date(field_name)
    value = params[field_name]
    return if value.blank?

    Date.iso8601(value.to_s)
  rescue Date::Error
    raise ArgumentError, "#{field_name} must be a valid date"
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

  def calendar_overlap_clause
    <<~SQL.squish
      (
        crm_tasks.due_on IS NULL AND
        COALESCE(crm_tasks.start_at, crm_tasks.due_at) < :to AND
        CASE
          WHEN crm_tasks.due_at IS NULL OR crm_tasks.due_at <= COALESCE(crm_tasks.start_at, crm_tasks.due_at)
            THEN COALESCE(crm_tasks.start_at, crm_tasks.due_at) + INTERVAL '1 hour'
          ELSE crm_tasks.due_at
        END >= :from
      ) OR (
        crm_tasks.due_on >= :from_date AND crm_tasks.due_on < :to_date
      )
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
