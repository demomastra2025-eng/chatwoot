class Crm::Reports::TaskLifecycleQuery # rubocop:disable Metrics/ClassLength
  MAX_WINDOW_DAYS = 366
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100
  QUERY_KIND = 'task_lifecycle'.freeze
  SOURCE = 'crm_events.task_terminal_lifecycle'.freeze
  LIFECYCLE_TYPES = %w[completed cancelled].freeze
  DEADLINE_STATES = %w[overdue on_time not_configured unknown].freeze
  EVENT_TYPES = {
    'task_completed' => 'completed',
    'task_cancelled' => 'cancelled'
  }.freeze

  attr_reader :account, :tasks_scope, :params, :timezone, :from_time, :to_time, :as_of_time

  def initialize(account:, tasks_scope:, params: {})
    @account = account
    @tasks_scope = tasks_scope
    @params = params.to_h.symbolize_keys
    @timezone = account.workspace_working_hours_timezone
    @zone = ActiveSupport::TimeZone[timezone]
    validate_zone!
    normalize_window!
    normalize_as_of!
    normalize_filters!
  end

  def aggregate_rows
    grouped_counts.map { |values| aggregate_payload(values) }
  end

  def drill_down_rows
    paginated_relation.map { |fact| drill_down_payload(fact) }
  end

  def total_count
    relation.count
  end

  def meta
    window_metadata.merge(reliability_metadata).merge(
      query_fingerprint: query_fingerprint,
      definition_version: 1,
      source: SOURCE
    ).merge(metric_definitions)
  end

  def pagination_meta
    meta.merge(page: page, per_page: per_page, total_count: total_count)
  end

  private

  attr_reader :zone, :lifecycle_type, :deadline_state

  def window_metadata
    {
      timezone: timezone,
      from: from_time.utc.iso8601(6),
      to: to_time.utc.iso8601(6),
      from_local: from_time.iso8601(6),
      to_local: to_time.iso8601(6),
      as_of: as_of_time.utc.iso8601(6),
      as_of_local: as_of_time.iso8601(6)
    }
  end

  def reliability_metadata
    {
      reliable_since: nil,
      unknown_before: nil,
      reliability_boundary: 'per_fact_only',
      coverage: overall_coverage
    }
  end

  def aggregate_payload(values)
    lifecycle_type, lifecycle_count, overdue_count, on_time_count, not_configured_count,
      unknown_deadline_count, exact_count, estimated_count, unknown_count = values
    {
      lifecycle_type: lifecycle_type,
      lifecycle_count: lifecycle_count.to_i,
      overdue_count: overdue_count.to_i,
      on_time_count: on_time_count.to_i,
      not_configured_count: not_configured_count.to_i,
      unknown_deadline_count: unknown_deadline_count.to_i,
      overdue_rate_percent: overdue_rate(overdue_count, on_time_count, unknown_deadline_count),
      exact_count: exact_count.to_i,
      estimated_count: estimated_count.to_i,
      unknown_count: unknown_count.to_i,
      coverage: coverage_for(estimated_count, unknown_count)
    }
  end

  def metric_definitions
    {
      cohort_definition: 'terminal_lifecycle_occurrences_in_window_observed_by_as_of',
      window_fact: 'terminal_at_with_event_created_at_fallback',
      completed_definition: 'canonical_task_completed_event',
      cancelled_definition: 'canonical_task_cancelled_event',
      overdue_definition: 'terminal_event_after_timed_due_at_or_after_workspace_end_of_due_on',
      retry_definition: 'one_persisted_event_per_successful_canonical_command'
    }
  end

  def normalize_window!
    from_date = parse_date!(:from_date)
    to_date = parse_date!(:to_date)
    days = (to_date - from_date).to_i + 1
    raise_validation!('to_date must be on or after from_date') if days < 1
    raise_validation!("date window must not exceed #{MAX_WINDOW_DAYS} days") if days > MAX_WINDOW_DAYS

    @from_time = zone.local(from_date.year, from_date.month, from_date.day)
    exclusive_date = to_date + 1.day
    @to_time = zone.local(exclusive_date.year, exclusive_date.month, exclusive_date.day)
  end

  def normalize_as_of!
    date = parse_date!(:as_of_date)
    raise_validation!('as_of_date must be on or after to_date') if date < (to_time.in_time_zone(timezone).to_date - 1.day)

    exclusive_date = date + 1.day
    @as_of_time = zone.local(exclusive_date.year, exclusive_date.month, exclusive_date.day)
  end

  def normalize_filters!
    @lifecycle_type = params[:lifecycle_type].presence&.to_s
    @deadline_state = params[:deadline_state].presence&.to_s
    raise_validation!('lifecycle_type is invalid') if lifecycle_type.present? && !lifecycle_type.in?(LIFECYCLE_TYPES)
    raise_validation!('deadline_state is invalid') if deadline_state.present? && !deadline_state.in?(DEADLINE_STATES)
  end

  def parse_date!(key)
    value = params[key]
    raise_validation!("#{key} is required") if value.blank?
    raise_validation!("#{key} must use YYYY-MM-DD") unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.iso8601(value.to_s)
  rescue Date::Error
    raise_validation!("#{key} must be a valid date")
  end

  def validate_zone!
    raise_validation!('workspace timezone is invalid') if zone.blank?
  end

  def relation
    @relation ||= begin
      scope = Crm::Event.unscoped.from("(#{facts_sql}) crm_events")
      scope = scope.where(lifecycle_type: lifecycle_type) if lifecycle_type.present?
      scope = scope.where(deadline_state: deadline_state) if deadline_state.present?
      scope
    end
  end

  def facts_sql # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    <<~SQL.squish
      SELECT
        events.id,
        events.eventable_id AS task_id,
        CASE events.event_type
          WHEN 'task_completed' THEN 'completed'
          WHEN 'task_cancelled' THEN 'cancelled'
        END AS lifecycle_type,
        #{lifecycle_at_sql} AS lifecycle_at,
        #{terminal_at_sql} AS terminal_at,
        CASE
          WHEN NULLIF(#{terminal_at_sql}, '') IS NULL AND events.schema_version = 1 THEN 'estimated'
          WHEN #{valid_terminal_at_sql} THEN 'exact'
          ELSE 'unknown'
        END AS lifecycle_reliability,
        CASE
          WHEN events.after_data->>'all_day' = 'true'
            AND #{valid_due_on_sql} THEN 'all_day'
          WHEN events.after_data->>'all_day' = 'false'
            AND #{valid_due_at_sql} THEN 'timed'
          WHEN events.after_data->>'all_day' = 'false'
            AND NULLIF(events.after_data->>'due_at', '') IS NULL THEN 'not_configured'
          ELSE 'unknown'
        END AS deadline_kind,
        events.after_data->>'due_at' AS due_at,
        events.after_data->>'due_on' AS due_on,
        CASE
          WHEN NOT (#{valid_terminal_at_sql}) THEN 'unknown'
          WHEN events.after_data->>'all_day' = 'true'
            AND #{valid_due_on_sql}
            AND TO_CHAR(
              (#{lifecycle_at_sql} AT TIME ZONE 'UTC') AT TIME ZONE #{connection.quote(timezone)},
              'YYYY-MM-DD'
            ) > events.after_data->>'due_on'
            THEN 'overdue'
          WHEN events.after_data->>'all_day' = 'true'
            AND #{valid_due_on_sql}
            THEN 'on_time'
          WHEN events.after_data->>'all_day' = 'false'
            AND #{valid_due_at_sql}
            AND #{lifecycle_at_sql} > #{parsed_due_at_sql}
            THEN 'overdue'
          WHEN events.after_data->>'all_day' = 'false'
            AND #{valid_due_at_sql}
            THEN 'on_time'
          WHEN events.after_data->>'all_day' = 'false'
            AND NULLIF(events.after_data->>'due_at', '') IS NULL THEN 'not_configured'
          ELSE 'unknown'
        END AS deadline_state,
        events.schema_version,
        events.correlation_id
      FROM crm_events events
      INNER JOIN (#{visible_tasks_sql}) visible_tasks ON visible_tasks.id = events.eventable_id
      WHERE events.account_id = #{connection.quote(account.id)}
        AND events.eventable_type = 'Crm::Task'
        AND events.event_type IN (#{EVENT_TYPES.keys.map { |value| connection.quote(value) }.join(', ')})
        AND #{lifecycle_at_sql} >= #{connection.quote(from_time.utc)}
        AND #{lifecycle_at_sql} < #{connection.quote(to_time.utc)}
        AND events.created_at < #{connection.quote(as_of_time.utc)}
    SQL
  end

  def visible_tasks_sql
    tasks_scope.reselect(:id).to_sql
  end

  def terminal_at_sql
    <<~SQL.squish
      CASE events.event_type
        WHEN 'task_completed' THEN events.after_data->>'completed_at'
        WHEN 'task_cancelled' THEN events.after_data->>'cancelled_at'
      END
    SQL
  end

  def valid_terminal_at_sql
    "events.schema_version = 1 AND #{terminal_at_sql} ~ #{connection.quote(timestamp_pattern)} " \
      "AND COALESCE(pg_input_is_valid(#{terminal_at_sql}, 'timestamptz'), FALSE)"
  end

  def lifecycle_at_sql
    <<~SQL.squish
      CASE WHEN #{valid_terminal_at_sql}
        THEN ((#{terminal_at_sql})::timestamptz AT TIME ZONE 'UTC')
        ELSE events.created_at
      END
    SQL
  end

  def valid_due_at_sql
    "events.after_data->>'due_at' ~ #{connection.quote(timestamp_pattern)} " \
      "AND COALESCE(pg_input_is_valid(events.after_data->>'due_at', 'timestamptz'), FALSE)"
  end

  def parsed_due_at_sql
    <<~SQL.squish
      CASE WHEN #{valid_due_at_sql}
        THEN ((events.after_data->>'due_at')::timestamptz AT TIME ZONE 'UTC')
        ELSE NULL
      END
    SQL
  end

  def valid_due_on_sql
    "events.after_data->>'due_on' ~ '^\\d{4}-\\d{2}-\\d{2}$' " \
      "AND COALESCE(pg_input_is_valid(events.after_data->>'due_on', 'date'), FALSE)"
  end

  def timestamp_pattern
    '^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d+)?(Z|[+-]\\d{2}:\\d{2})$'
  end

  def grouped_counts
    relation.group(:lifecycle_type).order(:lifecycle_type).pluck(
      :lifecycle_type,
      Arel.sql('COUNT(*)'),
      Arel.sql("COUNT(*) FILTER (WHERE deadline_state = 'overdue')"),
      Arel.sql("COUNT(*) FILTER (WHERE deadline_state = 'on_time')"),
      Arel.sql("COUNT(*) FILTER (WHERE deadline_state = 'not_configured')"),
      Arel.sql("COUNT(*) FILTER (WHERE deadline_state = 'unknown')"),
      Arel.sql("COUNT(*) FILTER (WHERE lifecycle_reliability = 'exact')"),
      Arel.sql("COUNT(*) FILTER (WHERE lifecycle_reliability = 'estimated')"),
      Arel.sql("COUNT(*) FILTER (WHERE lifecycle_reliability = 'unknown')")
    )
  end

  def overdue_rate(overdue_count, on_time_count, unknown_deadline_count)
    return if unknown_deadline_count.to_i.positive?

    denominator = overdue_count.to_i + on_time_count.to_i
    return if denominator.zero?

    ((overdue_count.to_f / denominator) * 100).round(3)
  end

  def coverage_for(estimated_count, unknown_count)
    return 'unknown' if unknown_count.to_i.positive?
    return 'estimated' if estimated_count.to_i.positive?

    'exact'
  end

  def overall_coverage
    return 'unknown' if !relation.exists? || relation.exists?(lifecycle_reliability: 'unknown')
    return 'estimated' if relation.exists?(lifecycle_reliability: 'estimated')

    'exact'
  end

  def paginated_relation
    relation.order(lifecycle_at: :desc, id: :desc).offset((page - 1) * per_page).limit(per_page)
  end

  def drill_down_payload(fact)
    {
      lifecycle_event_id: fact.id,
      task_id: fact.task_id,
      lifecycle_type: fact.lifecycle_type,
      lifecycle_at: fact.lifecycle_at&.utc&.iso8601(6),
      terminal_at: fact.terminal_at,
      lifecycle_reliability: fact.lifecycle_reliability,
      deadline: deadline_payload(fact),
      deadline_state: fact.deadline_state,
      schema_version: fact.schema_version,
      correlation_id: fact.correlation_id
    }
  end

  def deadline_payload(fact)
    {
      kind: fact.deadline_kind,
      due_at: fact.deadline_kind == 'timed' ? fact.due_at : nil,
      due_on: fact.deadline_kind == 'all_day' ? fact.due_on : nil,
      timezone: fact.deadline_kind == 'all_day' ? timezone : nil
    }
  end

  def page
    @page ||= parse_positive_integer!(:page, default: 1)
  end

  def per_page
    @per_page ||= parse_positive_integer!(:per_page, default: DEFAULT_PER_PAGE, max: MAX_PER_PAGE)
  end

  def parse_positive_integer!(key, default:, max: nil)
    value = params[key].presence || default
    raise_validation!("#{key} must be a positive integer") unless value.to_s.match?(/\A[1-9]\d*\z/)

    parsed = value.to_i
    raise_validation!("#{key} must not exceed #{max}") if max && parsed > max

    parsed
  end

  def query_fingerprint
    @query_fingerprint ||= Digest::SHA256.hexdigest(
      [
        QUERY_KIND, account.id, visible_tasks_sql, from_time.utc.iso8601(6), to_time.utc.iso8601(6),
        as_of_time.utc.iso8601(6), lifecycle_type, deadline_state
      ].to_json
    )
  end

  def connection
    ActiveRecord::Base.connection
  end

  def raise_validation!(message)
    raise Crm::Error.new(code: 'INVALID_REPORT_QUERY', message: message, status: :unprocessable_content)
  end
end
