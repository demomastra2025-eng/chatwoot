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
  ATTRIBUTION_GROUP_COLUMNS = %w[
    assignee_snapshot_present assignee_snapshot_blank assignee_id_snapshot assignee_catalog_id assignee_name
    team_snapshot_present team_snapshot_blank team_id_snapshot team_catalog_id team_name
    terminal_actor_snapshot_present terminal_actor_id_snapshot
    terminal_actor_catalog_id terminal_actor_name event_actor_type event_actor_id event_actor_state
    performed_by_type performed_by_id performed_by_state
  ].freeze

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
      definition_version: 2,
      source: SOURCE
    ).merge(metric_definitions)
  end

  def pagination_meta
    meta.merge(page: page, per_page: per_page, total_count: total_count)
  end

  def fact_relation
    @fact_relation ||= Crm::Event.unscoped.from("(#{facts_sql}) crm_events")
  end

  def attribution_payloads(values)
    {
      terminal_responsibility: responsibility_payloads(values),
      action_actor: action_actor_payload(values)
    }
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
    lifecycle_count, overdue_count, on_time_count, not_configured_count,
      unknown_deadline_count, exact_count, estimated_count, unknown_count = values.drop(1)
    {
      lifecycle_type: values.first,
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
      responsibility_definition: 'terminal_event_assignee_and_team_snapshots_not_current_task_assignment',
      action_actor_definition: 'terminal_actor_snapshot_with_typed_event_actor_and_performer_provenance',
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
      scope = fact_relation
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
        events.after_data->>'task_type_id' AS task_type_id_snapshot,
        events.after_data->>'task_outcome_id' AS task_outcome_id_snapshot,
        events.after_data->>'outcome' AS legacy_outcome_snapshot,
        events.after_data ? 'assignee_id' AS assignee_snapshot_present,
        NULLIF(events.after_data->>'assignee_id', '') IS NULL AS assignee_snapshot_blank,
        #{snapshot_id_sql("events.after_data->>'assignee_id'")} AS assignee_id_snapshot,
        assignee_memberships.user_id AS assignee_catalog_id,
        assignees.name AS assignee_name,
        events.after_data ? 'team_id' AS team_snapshot_present,
        NULLIF(events.after_data->>'team_id', '') IS NULL AS team_snapshot_blank,
        #{snapshot_id_sql("events.after_data->>'team_id'")} AS team_id_snapshot,
        terminal_teams.id AS team_catalog_id,
        terminal_teams.name AS team_name,
        #{terminal_actor_presence_sql} AS terminal_actor_snapshot_present,
        #{snapshot_id_sql(terminal_actor_id_sql)} AS terminal_actor_id_snapshot,
        terminal_actor_memberships.user_id AS terminal_actor_catalog_id,
        terminal_actors.name AS terminal_actor_name,
        events.actor_kind AS event_actor_type,
        #{typed_actor_id_sql('events.actor_kind', 'events.actor_id')} AS event_actor_id,
        #{typed_actor_state_sql('events.actor_kind', 'events.actor_id')} AS event_actor_state,
        events.performed_by_type,
        #{typed_actor_id_sql('events.performed_by_type', 'events.performed_by_id')} AS performed_by_id,
        #{typed_actor_state_sql('events.performed_by_type', 'events.performed_by_id')} AS performed_by_state,
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
      LEFT JOIN account_users assignee_memberships
        ON assignee_memberships.user_id = #{snapshot_id_sql("events.after_data->>'assignee_id'")}
        AND assignee_memberships.account_id = #{connection.quote(account.id)}
      LEFT JOIN users assignees ON assignees.id = assignee_memberships.user_id
      LEFT JOIN teams terminal_teams
        ON terminal_teams.id = #{snapshot_id_sql("events.after_data->>'team_id'")}
        AND terminal_teams.account_id = #{connection.quote(account.id)}
      LEFT JOIN account_users terminal_actor_memberships
        ON terminal_actor_memberships.user_id = #{snapshot_id_sql(terminal_actor_id_sql)}
        AND terminal_actor_memberships.account_id = #{connection.quote(account.id)}
      LEFT JOIN users terminal_actors ON terminal_actors.id = terminal_actor_memberships.user_id
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

  def valid_snapshot_id_sql(expression)
    "#{expression} ~ '^[1-9]\\d*$' AND COALESCE(pg_input_is_valid(#{expression}, 'bigint'), FALSE)"
  end

  def snapshot_id_sql(expression)
    "CASE WHEN #{valid_snapshot_id_sql(expression)} THEN (#{expression})::bigint END"
  end

  def typed_actor_id_sql(type_expression, id_expression)
    "CASE WHEN #{valid_typed_actor_sql(type_expression, id_expression)} THEN #{id_expression} END"
  end

  def typed_actor_state_sql(type_expression, id_expression)
    <<~SQL.squish
      CASE
        WHEN #{type_expression} = 'System' AND #{id_expression} IS NULL THEN 'system'
        WHEN #{valid_typed_actor_sql(type_expression, id_expression)} THEN 'persisted_typed_identity'
        ELSE 'unknown'
      END
    SQL
  end

  def valid_typed_actor_sql(type_expression, id_expression)
    "NULLIF(BTRIM(#{type_expression}), '') IS NOT NULL AND #{type_expression} <> 'System' AND #{id_expression} > 0"
  end

  def terminal_actor_id_sql
    <<~SQL.squish
      CASE events.event_type
        WHEN 'task_completed' THEN events.after_data->>'completed_by_id'
        WHEN 'task_cancelled' THEN events.after_data->>'cancelled_by_id'
      END
    SQL
  end

  def terminal_actor_presence_sql
    <<~SQL.squish
      CASE events.event_type
        WHEN 'task_completed' THEN events.after_data ? 'completed_by_id'
        WHEN 'task_cancelled' THEN events.after_data ? 'cancelled_by_id'
      END
    SQL
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
    attribution_values = ATTRIBUTION_GROUP_COLUMNS.map { |column| fact.public_send(column) }
    {
      lifecycle_event_id: fact.id,
      task_id: fact.task_id,
      lifecycle_type: fact.lifecycle_type,
      **attribution_payloads(attribution_values),
      lifecycle_at: fact.lifecycle_at&.utc&.iso8601(6),
      terminal_at: fact.terminal_at,
      lifecycle_reliability: fact.lifecycle_reliability,
      deadline: deadline_payload(fact),
      deadline_state: fact.deadline_state,
      schema_version: fact.schema_version,
      correlation_id: fact.correlation_id
    }
  end

  def responsibility_payloads(values)
    attributes = ATTRIBUTION_GROUP_COLUMNS.zip(values).to_h
    {
      assignee: responsibility_payload(attributes, :assignee),
      team: responsibility_payload(attributes, :team)
    }
  end

  def responsibility_payload(attributes, prefix)
    present = attributes.fetch("#{prefix}_snapshot_present")
    blank = attributes.fetch("#{prefix}_snapshot_blank")
    snapshot_id = attributes.fetch("#{prefix}_id_snapshot")
    catalog_id = attributes.fetch("#{prefix}_catalog_id")
    state = if present && blank
              'not_configured'
            elsif snapshot_id.blank?
              'unknown'
            elsif catalog_id.present?
              'current_catalog_projection'
            else
              'persisted_identity'
            end
    { id: snapshot_id, name: catalog_id.present? ? attributes.fetch("#{prefix}_name") : nil, state: state }
  end

  def action_actor_payload(values)
    attributes = ATTRIBUTION_GROUP_COLUMNS.zip(values).to_h
    {
      terminal: terminal_actor_payload(attributes),
      event: typed_actor_payload(
        type: attributes['event_actor_type'], id: attributes['event_actor_id'], state: attributes['event_actor_state']
      ),
      performed_by: typed_actor_payload(
        type: attributes['performed_by_type'], id: attributes['performed_by_id'], state: attributes['performed_by_state']
      )
    }
  end

  def terminal_actor_payload(attributes)
    snapshot_id = attributes['terminal_actor_id_snapshot']
    catalog_id = attributes['terminal_actor_catalog_id']
    state = if !attributes['terminal_actor_snapshot_present'] || snapshot_id.blank?
              'unknown'
            elsif catalog_id.present?
              'current_catalog_projection'
            else
              'persisted_identity'
            end
    { type: 'User', id: snapshot_id, name: catalog_id.present? ? attributes['terminal_actor_name'] : nil, state: state }
  end

  def typed_actor_payload(type:, id:, state:)
    { type: type, id: id, state: state }
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
