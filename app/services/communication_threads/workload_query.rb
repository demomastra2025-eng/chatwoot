class CommunicationThreads::WorkloadQuery # rubocop:disable Metrics/ClassLength
  class InvalidQuery < StandardError; end

  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100
  MAX_PAGE = 10_000
  DIMENSIONS = %w[owner team].freeze
  STATUSES = %w[open pending snoozed].freeze
  PRIORITIES = %w[low medium high urgent].freeze
  UNREAD_STATES = %w[with_unread without_unread].freeze
  QUERY_KIND = 'communication_thread_workload'.freeze
  SOURCE = 'communication_threads'.freeze
  UNASSIGNED = 'unassigned'.freeze
  TEMPORAL_PARAMS = %i[from to as_of from_date to_date as_of_date since until start_at end_at].freeze

  attr_reader :account, :dimension, :generated_at, :params, :timezone

  def initialize(account:, threads_scope:, params: {}, generated_at: Time.current)
    @account = account
    @threads_scope = threads_scope
    @params = params.to_h.symbolize_keys
    @generated_at = generated_at
    @timezone = account.workspace_working_hours_timezone
    reject_historical_query!
    normalize_filters!
  end

  def aggregate_rows = aggregate_result.fetch(:rows)
  def drill_down_rows = details_result.fetch(:rows)
  def meta = report_meta.merge(total_count: aggregate_result.fetch(:total_count))
  def pagination_meta = report_meta.merge(page: page, per_page: per_page, total_count: details_result.fetch(:total_count))

  def relation
    @relation ||= begin
      scope = threads_scope.where(account_id: account.id, status: CommunicationThread.statuses.values_at(*STATUSES))
      scope = scope.where(status: CommunicationThread.statuses.fetch(filters[:status])) if filters.key?(:status)
      scope = apply_priority_filter(scope)
      scope = apply_unread_filter(scope)
      scope = apply_attribution_filter(scope, :assignee_id)
      apply_attribution_filter(scope, :team_id)
    end
  end

  private

  attr_reader :threads_scope, :filters

  def reject_historical_query!
    unsupported = TEMPORAL_PARAMS.find { |key| params[key].present? }
    raise_invalid!("#{unsupported} is not supported for current snapshots") if unsupported
  end

  def normalize_filters!
    @dimension = params[:dimension].presence&.to_s
    raise_invalid!('dimension must be owner or team') if dimension.present? && DIMENSIONS.exclude?(dimension)

    @filters = {
      assignee_id: parse_attribution_filter!(:assignee_id),
      team_id: parse_attribution_filter!(:team_id),
      status: parse_enum_filter!(:status, STATUSES),
      priority: parse_priority_filter!,
      unread: parse_enum_filter!(:unread, UNREAD_STATES)
    }.compact
    validate_filters!
  end

  def validate_filters!
    raise_invalid!('dimension=owner is required with assignee_id') if filters.key?(:assignee_id) && dimension != 'owner'
    raise_invalid!('dimension=team is required with team_id') if filters.key?(:team_id) && dimension != 'team'
    validate_attribution_filter!(:assignee_id, account.users)
    validate_attribution_filter!(:team_id, account.teams)
  end

  def validate_attribution_filter!(key, catalog_scope)
    return unless filters.key?(key)
    return if filters[key] == UNASSIGNED

    value = filters[key]
    valid_catalog = catalog_scope.exists?(id: value)
    valid_visible_attribution = threads_scope.where(account_id: account.id).exists?(key => value)
    raise_invalid!("#{key} is invalid") unless valid_catalog && valid_visible_attribution
  end

  def apply_attribution_filter(scope, key)
    return scope unless filters.key?(key)

    value = filters[key] == UNASSIGNED ? nil : filters[key]
    scope.where(communication_threads: { key => value })
  end

  def apply_priority_filter(scope)
    return scope unless filters.key?(:priority)

    value = filters[:priority] == UNASSIGNED ? nil : CommunicationThread.priorities.fetch(filters[:priority])
    scope.where(communication_threads: { priority: value })
  end

  def apply_unread_filter(scope)
    case filters[:unread]
    when 'with_unread' then scope.where('communication_threads.unread_count > 0')
    when 'without_unread' then scope.where(communication_threads: { unread_count: 0 })
    else scope
    end
  end

  def aggregate_sql
    queries = selected_dimensions.map { |selected_dimension| dimension_aggregate_sql(selected_dimension) }
    <<~SQL.squish
      WITH matching_threads AS MATERIALIZED (#{report_relation.to_sql})
      SELECT buckets.*, totals.report_total_count
      FROM (SELECT COUNT(*) AS report_total_count FROM matching_threads) totals
      LEFT JOIN LATERAL (#{queries.join(' UNION ALL ')}) buckets ON TRUE
      ORDER BY buckets.dimension ASC, buckets.dimension_id ASC NULLS FIRST
    SQL
  end

  def dimension_aggregate_sql(selected_dimension) # rubocop:disable Metrics/MethodLength
    foreign_key = selected_dimension == 'owner' ? 'thread_assignee_id' : 'thread_team_id'
    join_sql, catalog_id, name = dimension_join(selected_dimension, "threads.#{foreign_key}")
    quoted_dimension = connection.quote(selected_dimension)

    <<~SQL.squish
      SELECT #{quoted_dimension} AS dimension, threads.#{foreign_key} AS dimension_id,
        #{catalog_id} AS catalog_id, #{name} AS dimension_name,
        COUNT(*) AS unresolved_count,
        COUNT(*) FILTER (WHERE threads.thread_status = #{CommunicationThread.statuses.fetch('open')}) AS open_count,
        COUNT(*) FILTER (WHERE threads.thread_status = #{CommunicationThread.statuses.fetch('pending')}) AS pending_count,
        COUNT(*) FILTER (WHERE threads.thread_status = #{CommunicationThread.statuses.fetch('snoozed')}) AS snoozed_count,
        COUNT(*) FILTER (WHERE threads.thread_priority = #{CommunicationThread.priorities.fetch('low')}) AS priority_low_count,
        COUNT(*) FILTER (WHERE threads.thread_priority = #{CommunicationThread.priorities.fetch('medium')}) AS priority_medium_count,
        COUNT(*) FILTER (WHERE threads.thread_priority = #{CommunicationThread.priorities.fetch('high')}) AS priority_high_count,
        COUNT(*) FILTER (WHERE threads.thread_priority = #{CommunicationThread.priorities.fetch('urgent')}) AS priority_urgent_count,
        COUNT(*) FILTER (WHERE threads.thread_priority IS NULL) AS priority_not_configured_count,
        COUNT(*) FILTER (WHERE threads.thread_unread_count > 0) AS unread_threads_count,
        COALESCE(SUM(threads.thread_unread_count), 0) AS unread_count,
        COUNT(*) FILTER (WHERE threads.thread_last_activity_at IS NULL) AS last_activity_unknown_count,
        MIN(threads.thread_last_activity_at) AS oldest_last_activity_at,
        MAX(threads.thread_last_activity_at) AS latest_last_activity_at
      FROM matching_threads threads
      #{join_sql}
      GROUP BY threads.#{foreign_key}, #{catalog_id}, #{name}
    SQL
  end

  def details_sql
    <<~SQL.squish
      WITH matching_threads AS MATERIALIZED (#{report_relation.to_sql})
      SELECT page.*, totals.report_total_count
      FROM (SELECT COUNT(*) AS report_total_count FROM matching_threads) totals
      LEFT JOIN LATERAL (
        SELECT threads.*,
          assignee_memberships.user_id AS assignee_catalog_id, assignees.name AS assignee_name,
          teams.id AS team_catalog_id, teams.name AS team_name
        FROM matching_threads threads
        LEFT JOIN account_users assignee_memberships
          ON assignee_memberships.user_id = threads.thread_assignee_id AND assignee_memberships.account_id = #{quoted_account_id}
        LEFT JOIN users assignees ON assignees.id = assignee_memberships.user_id
        LEFT JOIN teams ON teams.id = threads.thread_team_id AND teams.account_id = #{quoted_account_id}
        ORDER BY threads.thread_id ASC
        LIMIT #{per_page} OFFSET #{page_offset}
      ) page ON TRUE
    SQL
  end

  def report_relation
    relation.reselect(
      'communication_threads.id AS thread_id', 'communication_threads.display_id AS thread_display_id',
      'communication_threads.contact_id AS thread_contact_id',
      'communication_threads.assignee_id AS thread_assignee_id', 'communication_threads.team_id AS thread_team_id',
      'communication_threads.status AS thread_status', 'communication_threads.priority AS thread_priority',
      'communication_threads.unread_count AS thread_unread_count',
      'communication_threads.last_activity_at AS thread_last_activity_at'
    ).reorder(nil)
  end

  def aggregate_result
    @aggregate_result ||= begin
      result = connection.exec_query(aggregate_sql).to_a
      {
        rows: result.filter_map { |row| aggregate_payload(row) if row['dimension'] },
        total_count: result.first.fetch('report_total_count').to_i
      }
    end
  end

  def details_result
    @details_result ||= begin
      result = connection.exec_query(details_sql).to_a
      {
        rows: result.filter_map { |row| detail_payload(row) if row['thread_id'] },
        total_count: result.first.fetch('report_total_count').to_i
      }
    end
  end

  def aggregate_payload(row)
    {
      dimension: row['dimension'],
      attribution: attribution_payload(raw_id: row['dimension_id'], catalog_id: row['catalog_id'], name: row['dimension_name']),
      **integer_payload(row),
      oldest_last_activity_at: iso8601(row['oldest_last_activity_at']),
      latest_last_activity_at: iso8601(row['latest_last_activity_at'])
    }
  end

  def integer_payload(row)
    %w[
      unresolved_count open_count pending_count snoozed_count
      priority_low_count priority_medium_count priority_high_count priority_urgent_count priority_not_configured_count
      unread_threads_count unread_count last_activity_unknown_count
    ].index_with { |key| row[key].to_i }.symbolize_keys
  end

  def detail_payload(row)
    {
      communication_thread_id: row['thread_id'],
      display_id: row['thread_display_id'],
      contact_id: row['thread_contact_id'],
      owner: attribution_payload(raw_id: row['thread_assignee_id'], catalog_id: row['assignee_catalog_id'], name: row['assignee_name']),
      team: attribution_payload(raw_id: row['thread_team_id'], catalog_id: row['team_catalog_id'], name: row['team_name']),
      status: CommunicationThread.statuses.key(row['thread_status'].to_i),
      priority: row['thread_priority'].nil? ? nil : CommunicationThread.priorities.key(row['thread_priority'].to_i),
      unread_count: row['thread_unread_count'].to_i,
      last_activity_at: iso8601(row['thread_last_activity_at'])
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

  def dimension_join(selected_dimension, foreign_key)
    if selected_dimension == 'owner'
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

  def report_meta
    {
      metric_kind: 'current_snapshot', reliability: 'exact',
      generated_at: generated_at.utc.iso8601(6), generated_at_local: generated_at.in_time_zone(timezone).iso8601(6),
      timezone: timezone, definition_version: 1, source_version: 1, source: SOURCE,
      query_fingerprint: query_fingerprint,
      cohort_definition: 'communication_thread_view_intersect_view_reports_owner_scope_unresolved_at_generated_at',
      status_definition: 'unresolved_is_open_pending_or_snoozed_resolved_is_excluded',
      unread_definition: 'persisted_thread_unread_count_current_projection',
      last_activity_definition: 'persisted_thread_last_activity_at_current_projection_missing_is_unknown',
      attribution_definition: 'persisted_thread_assignee_is_canonical_owner_owner_and_team_are_independent_dimensions',
      participant_definition: 'participant_membership_never_grants_owner_workload_credit',
      temporal_definition: 'exact_current_snapshot_not_historical',
      historical_attribution: 'unknown_not_supported',
      sla_state: 'not_configured_not_supported',
      combination_definition: 'owner_and_team_dimensions_must_not_be_summed'
    }
  end

  def parse_enum_filter!(key, allowed)
    return if params[key].blank?

    value = params[key].to_s
    raise_invalid!("#{key} is invalid") unless allowed.include?(value)
    value
  end

  def parse_priority_filter!
    return if params[:priority].blank?
    return UNASSIGNED if params[:priority].to_s == UNASSIGNED

    parse_enum_filter!(:priority, PRIORITIES)
  end

  def parse_attribution_filter!(key)
    return if params[key].blank?
    return UNASSIGNED if params[key].to_s == UNASSIGNED

    parse_positive_integer!(key, default: nil)
  end

  def parse_positive_integer!(key, default:, max: nil)
    value = params[key].presence || default
    raise_invalid!("#{key} must be a positive integer or unassigned") unless value.to_s.match?(/\A[1-9]\d*\z/)

    parsed = value.to_i
    raise_invalid!("#{key} must not exceed #{max}") if max && parsed > max
    parsed
  end

  def page = @page ||= parse_positive_integer!(:page, default: 1, max: MAX_PAGE)
  def per_page = @per_page ||= parse_positive_integer!(:per_page, default: DEFAULT_PER_PAGE, max: MAX_PER_PAGE)
  def page_offset = (page - 1) * per_page

  def query_fingerprint
    @query_fingerprint ||= Digest::SHA256.hexdigest(
      [QUERY_KIND, account.id, threads_scope.to_sql, dimension, filters.sort].to_json
    )
  end

  def iso8601(value) = value&.iso8601(6)
  def connection = ActiveRecord::Base.connection
  def quoted_account_id = connection.quote(account.id)
  def raise_invalid!(message) = raise InvalidQuery, message
end
