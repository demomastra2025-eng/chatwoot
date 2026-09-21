class Crm::Reports::TaskWorkloadQuery # rubocop:disable Metrics/ClassLength
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100
  MAX_PAGE = 10_000
  DIMENSIONS = %w[assignee team].freeze
  DUE_STATES = %w[overdue today future unscheduled unknown].freeze
  QUERY_KIND = 'task_workload'.freeze
  SOURCE = 'crm_tasks'.freeze
  UNASSIGNED = 'unassigned'.freeze

  attr_reader :account, :dimension, :generated_at, :params, :timezone

  def initialize(account:, tasks_scope:, params: {}, generated_at: Time.current)
    @account = account
    @tasks_scope = tasks_scope
    @params = params.to_h.symbolize_keys
    @generated_at = generated_at
    @timezone = account.workspace_working_hours_timezone
    @zone = ActiveSupport::TimeZone[timezone]
    validate_zone!
    reject_historical_query!
    normalize_filters!
  end

  def aggregate_rows = aggregate_result.fetch(:rows)
  def drill_down_rows = details_result.fetch(:rows)
  def meta = report_meta.merge(total_count: aggregate_result.fetch(:total_count))
  def pagination_meta = report_meta.merge(page: page, per_page: per_page, total_count: details_result.fetch(:total_count))

  def relation # rubocop:disable Metrics/AbcSize
    @relation ||= begin
      scope = tasks_scope.where(account_id: account.id, archived_at: nil, completed_at: nil, cancelled_at: nil)
      scope = scope.joins(tenant_catalog_join('crm_task_statuses', 'workload_statuses', 'status_id'))
                   .where(workload_statuses: { category: %w[open in_progress] })
      scope = scope.where(crm_tasks: { status_id: filters[:status_id] }) if filters.key?(:status_id)
      scope = scope.where(crm_tasks: { task_type_id: filters[:task_type_id] }) if filters.key?(:task_type_id)
      scope = scope.where("#{due_state_sql} = ?", filters[:due_state]) if filters.key?(:due_state)
      scope = apply_attribution_filter(scope, :assignee_id)
      apply_attribution_filter(scope, :team_id)
    end
  end

  private

  attr_reader :tasks_scope, :filters, :zone

  def validate_zone!
    raise_validation!('workspace timezone is invalid') if zone.blank?
  end

  def reject_historical_query!
    unsupported = %i[from to as_of from_date to_date as_of_date].find { |key| params[key].present? }
    raise_validation!("#{unsupported} is not supported for current snapshots") if unsupported
  end

  def normalize_filters!
    @dimension = params[:dimension].presence&.to_s
    raise_validation!('dimension must be assignee or team') if dimension.present? && DIMENSIONS.exclude?(dimension)

    @filters = {
      status_id: parse_optional_positive_integer!(:status_id),
      task_type_id: parse_optional_positive_integer!(:task_type_id),
      assignee_id: parse_attribution_filter!(:assignee_id),
      team_id: parse_attribution_filter!(:team_id),
      due_state: parse_due_state!
    }.compact
    validate_filters!
  end

  def validate_filters!
    raise_validation!('dimension=assignee is required with assignee_id') if filters.key?(:assignee_id) && dimension != 'assignee'
    raise_validation!('dimension=team is required with team_id') if filters.key?(:team_id) && dimension != 'team'
    validate_filter!(:status_id, account.crm_task_statuses.where(category: %w[open in_progress]))
    validate_filter!(:task_type_id, account.crm_task_types)
    validate_attribution_filter!(:assignee_id, account.users)
    validate_attribution_filter!(:team_id, account.teams)
  end

  def validate_filter!(key, scope)
    return unless filters[key]

    raise_validation!("#{key} is invalid") unless scope.exists?(id: filters[key])
  end

  def validate_attribution_filter!(key, catalog_scope)
    return unless filters.key?(key)

    value = filters[key] == UNASSIGNED ? nil : filters[key]
    valid_catalog = value.nil? || catalog_scope.exists?(id: value)
    valid_visible_attribution = tasks_scope.where(account_id: account.id).exists?(key => value)
    raise_validation!("#{key} is invalid") unless valid_catalog && valid_visible_attribution
  end

  def apply_attribution_filter(scope, key)
    return scope unless filters.key?(key)

    value = filters[key] == UNASSIGNED ? nil : filters[key]
    scope.where(crm_tasks: { key => value })
  end

  def aggregate_sql
    queries = selected_dimensions.map { |selected_dimension| dimension_aggregate_sql(selected_dimension) }
    <<~SQL.squish
      WITH matching_tasks AS MATERIALIZED (#{report_relation.to_sql})
      SELECT buckets.*, totals.report_total_count
      FROM (SELECT COUNT(*) AS report_total_count FROM matching_tasks) totals
      LEFT JOIN LATERAL (#{queries.join(' UNION ALL ')}) buckets ON TRUE
      ORDER BY buckets.dimension ASC, buckets.dimension_id ASC NULLS FIRST
    SQL
  end

  def dimension_aggregate_sql(selected_dimension)
    foreign_key = "task_#{selected_dimension}_id"
    join_sql, catalog_id, name = dimension_join(selected_dimension, "tasks.#{foreign_key}")
    quoted_dimension = connection.quote(selected_dimension)
    counts = DUE_STATES.map do |state|
      "COUNT(*) FILTER (WHERE tasks.due_state = #{connection.quote(state)}) AS #{state}_count"
    end.join(', ')

    <<~SQL.squish
      SELECT #{quoted_dimension} AS dimension, tasks.#{foreign_key} AS dimension_id,
        #{catalog_id} AS catalog_id, #{name} AS dimension_name,
        COUNT(*) AS open_count, #{counts}
      FROM matching_tasks tasks
      #{join_sql}
      GROUP BY tasks.#{foreign_key}, #{catalog_id}, #{name}
    SQL
  end

  def details_sql # rubocop:disable Metrics/MethodLength
    <<~SQL.squish
      WITH matching_tasks AS MATERIALIZED (#{report_relation.to_sql})
      SELECT page.*, totals.report_total_count
      FROM (SELECT COUNT(*) AS report_total_count FROM matching_tasks) totals
      LEFT JOIN LATERAL (
        SELECT tasks.*,
          assignee_memberships.user_id AS assignee_catalog_id, assignees.name AS assignee_name,
          teams.id AS team_catalog_id, teams.name AS team_name,
          statuses.name AS status_name, types.name AS task_type_name
        FROM matching_tasks tasks
        LEFT JOIN account_users assignee_memberships
          ON assignee_memberships.user_id = tasks.task_assignee_id AND assignee_memberships.account_id = #{quoted_account_id}
        LEFT JOIN users assignees ON assignees.id = assignee_memberships.user_id
        LEFT JOIN teams ON teams.id = tasks.task_team_id AND teams.account_id = #{quoted_account_id}
        INNER JOIN crm_task_statuses statuses
          ON statuses.id = tasks.task_status_id AND statuses.account_id = #{quoted_account_id}
        LEFT JOIN crm_task_types types
          ON types.id = tasks.task_type_id AND types.account_id = #{quoted_account_id}
        ORDER BY tasks.task_id ASC
        LIMIT #{per_page} OFFSET #{page_offset}
      ) page ON TRUE
    SQL
  end

  def report_relation
    relation.reselect(
      'crm_tasks.id AS task_id', 'crm_tasks.title', 'crm_tasks.all_day',
      'crm_tasks.due_at', 'crm_tasks.due_on', 'crm_tasks.schedule_timezone',
      'crm_tasks.assignee_id AS task_assignee_id', 'crm_tasks.team_id AS task_team_id',
      'crm_tasks.status_id AS task_status_id', 'crm_tasks.task_type_id AS task_type_id',
      "#{due_state_sql} AS due_state"
    ).reorder(nil)
  end

  def due_state_sql # rubocop:disable Metrics/MethodLength
    @due_state_sql ||= <<~SQL.squish
      CASE
        WHEN crm_tasks.all_day = TRUE AND crm_tasks.due_on IS NOT NULL
          AND crm_tasks.due_at IS NULL AND crm_tasks.start_at IS NULL
          AND crm_tasks.due_on < #{connection.quote(workspace_date)} THEN 'overdue'
        WHEN crm_tasks.all_day = TRUE AND crm_tasks.due_on IS NOT NULL
          AND crm_tasks.due_at IS NULL AND crm_tasks.start_at IS NULL
          AND crm_tasks.due_on = #{connection.quote(workspace_date)} THEN 'today'
        WHEN crm_tasks.all_day = TRUE AND crm_tasks.due_on IS NOT NULL
          AND crm_tasks.due_at IS NULL AND crm_tasks.start_at IS NULL
          AND crm_tasks.due_on > #{connection.quote(workspace_date)} THEN 'future'
        WHEN crm_tasks.all_day = FALSE AND crm_tasks.due_on IS NULL
          AND crm_tasks.due_at IS NOT NULL AND crm_tasks.due_at < #{connection.quote(generated_at)} THEN 'overdue'
        WHEN crm_tasks.all_day = FALSE AND crm_tasks.due_on IS NULL
          AND crm_tasks.due_at IS NOT NULL AND crm_tasks.due_at >= #{connection.quote(generated_at)}
          AND DATE((crm_tasks.due_at AT TIME ZONE 'UTC') AT TIME ZONE #{connection.quote(timezone)}) = #{connection.quote(workspace_date)}
          THEN 'today'
        WHEN crm_tasks.all_day = FALSE AND crm_tasks.due_on IS NULL
          AND crm_tasks.due_at IS NOT NULL AND crm_tasks.due_at >= #{connection.quote(generated_at)} THEN 'future'
        WHEN crm_tasks.all_day = FALSE AND crm_tasks.due_on IS NULL AND crm_tasks.due_at IS NULL THEN 'unscheduled'
        ELSE 'unknown'
      END
    SQL
  end

  def details_result
    @details_result ||= begin
      result = connection.exec_query(details_sql).to_a
      { rows: result.filter_map { |row| detail_payload(row) if row['task_id'] },
        total_count: result.first.fetch('report_total_count').to_i }
    end
  end

  def aggregate_result
    @aggregate_result ||= begin
      result = connection.exec_query(aggregate_sql).to_a
      { rows: result.filter_map { |row| aggregate_payload(row) if row['dimension'] },
        total_count: result.first.fetch('report_total_count').to_i }
    end
  end

  def aggregate_payload(row)
    {
      dimension: row['dimension'],
      attribution: attribution_payload(raw_id: row['dimension_id'], catalog_id: row['catalog_id'], name: row['dimension_name']),
      open_count: row['open_count'].to_i,
      overdue_count: row['overdue_count'].to_i,
      today_count: row['today_count'].to_i,
      future_count: row['future_count'].to_i,
      unscheduled_count: row['unscheduled_count'].to_i,
      unknown_count: row['unknown_count'].to_i
    }
  end

  def detail_payload(row)
    {
      task_id: row['task_id'], title: row['title'],
      assignee: attribution_payload(raw_id: row['task_assignee_id'], catalog_id: row['assignee_catalog_id'], name: row['assignee_name']),
      team: attribution_payload(raw_id: row['task_team_id'], catalog_id: row['team_catalog_id'], name: row['team_name']),
      status: { id: row['task_status_id'], name: row['status_name'], state: 'current_catalog_projection' },
      task_type: catalog_payload(raw_id: row['task_type_id'], name: row['task_type_name']),
      due_state: row['due_state'], all_day: row['all_day'],
      due_at: row['due_at']&.iso8601(6), due_on: row['due_on']&.to_s,
      schedule_timezone: row['schedule_timezone']
    }
  end

  def attribution_payload(raw_id:, catalog_id:, name:)
    state = if raw_id.blank?
              'not_configured'
            elsif catalog_id.present?
              'current_catalog_projection'
            else
              'unknown'
            end
    { id: raw_id, name: catalog_id.present? ? name : nil, state: state }
  end

  def catalog_payload(raw_id:, name:)
    state = if raw_id.blank?
              'not_configured'
            elsif name.present?
              'current_catalog_projection'
            else
              'unknown'
            end
    { id: raw_id, name: name, state: state }
  end

  def dimension_join(selected_dimension, foreign_key)
    if selected_dimension == 'assignee'
      join_sql = <<~SQL.squish
        LEFT JOIN account_users dimension_memberships
          ON dimension_memberships.user_id = #{foreign_key} AND dimension_memberships.account_id = #{quoted_account_id}
        LEFT JOIN users dimension_users ON dimension_users.id = dimension_memberships.user_id
      SQL
      [join_sql, 'dimension_memberships.user_id', 'dimension_users.name']
    else
      ["LEFT JOIN teams dimension_teams ON dimension_teams.id = #{foreign_key} AND dimension_teams.account_id = #{quoted_account_id}",
       'dimension_teams.id', 'dimension_teams.name']
    end
  end

  def selected_dimensions = dimension.present? ? [dimension] : DIMENSIONS

  def tenant_catalog_join(table, alias_name, foreign_key)
    "INNER JOIN #{table} #{alias_name} ON #{alias_name}.id = crm_tasks.#{foreign_key} " \
      "AND #{alias_name}.account_id = #{quoted_account_id}"
  end

  def report_meta
    {
      metric_kind: 'current_snapshot', reliability: 'exact',
      generated_at: generated_at.utc.iso8601(6), generated_at_local: generated_at.in_time_zone(timezone).iso8601(6),
      timezone: timezone, workspace_date: workspace_date.iso8601,
      definition_version: 1, source_version: 1, source: SOURCE, query_fingerprint: query_fingerprint,
      cohort_definition: 'task_view_intersect_view_reports_kept_open_or_in_progress_without_terminal_columns_at_generated_at',
      due_state_definition: 'timed_deadlines_compare_instants_then_workspace_local_date_' \
                            'all_day_deadlines_compare_workspace_date_missing_is_unscheduled_invalid_shape_is_unknown',
      attribution_definition: 'persisted_assignee_and_team_are_independent_dimensions_current_catalog_labels_do_not_rewrite_attribution',
      temporal_definition: 'exact_current_snapshot_not_historical_reopen_affects_only_later_snapshots',
      historical_attribution: 'unknown_not_supported',
      combination_definition: 'assignee_and_team_dimensions_must_not_be_summed'
    }
  end

  def parse_due_state!
    return if params[:due_state].blank?

    value = params[:due_state].to_s
    raise_validation!('due_state is invalid') unless DUE_STATES.include?(value)
    value
  end

  def parse_attribution_filter!(key)
    return if params[key].blank?
    return UNASSIGNED if params[key].to_s == UNASSIGNED

    parse_positive_integer!(key, default: nil)
  end

  def parse_optional_positive_integer!(key)
    return if params[key].blank?

    parse_positive_integer!(key, default: nil)
  end

  def parse_positive_integer!(key, default:, max: nil)
    value = params[key].presence || default
    raise_validation!("#{key} must be a positive integer or unassigned") unless value.to_s.match?(/\A[1-9]\d*\z/)
    parsed = value.to_i
    raise_validation!("#{key} must not exceed #{max}") if max && parsed > max
    parsed
  end

  def page = @page ||= parse_positive_integer!(:page, default: 1, max: MAX_PAGE)
  def per_page = @per_page ||= parse_positive_integer!(:per_page, default: DEFAULT_PER_PAGE, max: MAX_PER_PAGE)
  def page_offset = (page - 1) * per_page
  def workspace_date = @workspace_date ||= generated_at.in_time_zone(zone).to_date

  def query_fingerprint
    @query_fingerprint ||= Digest::SHA256.hexdigest(
      [QUERY_KIND, account.id, tasks_scope.to_sql, dimension, filters.sort].to_json
    )
  end

  def connection = ActiveRecord::Base.connection
  def quoted_account_id = connection.quote(account.id)

  def raise_validation!(message)
    raise Crm::Error.new(code: 'INVALID_REPORT_QUERY', message: message, status: :unprocessable_content)
  end
end
