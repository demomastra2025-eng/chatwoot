class Crm::Reports::DealTerminalOutcomesQuery # rubocop:disable Metrics/ClassLength
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100
  MAX_PAGE = 10_000
  MAX_WINDOW_DAYS = 366
  DIMENSIONS = %w[owner team].freeze
  OUTCOMES = %w[won lost].freeze
  QUERY_KIND = 'deal_terminal_outcomes'.freeze
  SOURCE = 'crm_stage_visits'.freeze
  SPECIAL_ATTRIBUTIONS = %w[unassigned unknown].freeze

  attr_reader :account, :as_of_time, :dimension, :from_time, :params, :timezone, :to_time

  def initialize(account:, deals_scope:, params: {})
    @account = account
    @deals_scope = deals_scope
    @params = params.to_h.symbolize_keys
    @timezone = account.workspace_working_hours_timezone
    @zone = ActiveSupport::TimeZone[timezone]
    validate_zone!
    normalize_window!
    normalize_filters!
  end

  def aggregate_rows
    aggregate_result.fetch(:rows)
  end

  def drill_down_rows
    details_result.fetch(:rows)
  end

  def meta
    report_meta(aggregate_result)
  end

  def pagination_meta
    report_meta(details_result).merge(page: page, per_page: per_page)
  end

  private

  attr_reader :deals_scope, :filters, :zone

  def normalize_window!
    from_date = parse_date!(:from_date)
    to_date = parse_date!(:to_date)
    days = (to_date - from_date).to_i + 1
    raise_validation!('to_date must be on or after from_date') if days < 1
    raise_validation!("date window must not exceed #{MAX_WINDOW_DAYS} days") if days > MAX_WINDOW_DAYS

    @from_time = zone.local(from_date.year, from_date.month, from_date.day)
    exclusive_date = to_date + 1.day
    @to_time = zone.local(exclusive_date.year, exclusive_date.month, exclusive_date.day)
    normalize_as_of!(to_date)
  end

  def normalize_as_of!(to_date)
    as_of_date = parse_date!(:as_of_date)
    raise_validation!('as_of_date must be on or after to_date') if as_of_date < to_date

    exclusive_date = as_of_date + 1.day
    @as_of_time = zone.local(exclusive_date.year, exclusive_date.month, exclusive_date.day)
  end

  def normalize_filters!
    @dimension = params[:dimension].presence&.to_s
    raise_validation!('dimension must be owner or team') if dimension.present? && DIMENSIONS.exclude?(dimension)

    @filters = {
      outcome: normalize_outcome!,
      owner_id: parse_attribution_filter!(:owner_id),
      team_id: parse_attribution_filter!(:team_id)
    }.compact
    validate_dimension_filters!
    validate_attribution_filter!(:owner_id)
    validate_attribution_filter!(:team_id)
  end

  def normalize_outcome!
    value = params[:outcome].presence&.to_s
    raise_validation!('outcome must be won or lost') if value.present? && OUTCOMES.exclude?(value)

    value
  end

  def validate_dimension_filters!
    raise_validation!('dimension=owner is required with owner_id') if filters.key?(:owner_id) && dimension != 'owner'
    raise_validation!('dimension=team is required with team_id') if filters.key?(:team_id) && dimension != 'team'
  end

  def validate_attribution_filter!(key)
    return unless filters.key?(key)

    column = key == :owner_id ? 'owner_id_at_terminal' : 'team_id_at_terminal'
    value = filters.fetch(key)
    predicate = attribution_filter_predicate(column, value)
    validation_sql = "SELECT 1 FROM (#{unfiltered_occurrences_sql}) terminal_occurrences WHERE #{predicate} LIMIT 1"
    raise_validation!("#{key} is invalid") unless connection.select_value(validation_sql)
  end

  def aggregate_sql
    queries = selected_dimensions.map { |selected_dimension| dimension_aggregate_sql(selected_dimension) }
    <<~SQL.squish
      WITH terminal_occurrences AS MATERIALIZED (#{filtered_occurrences_sql})
      SELECT buckets.*, totals.report_total_count, totals.exact_count, totals.unknown_count
      FROM (
        SELECT COUNT(*) AS report_total_count,
          COUNT(*) FILTER (WHERE terminal_attribution_version = 1) AS exact_count,
          COUNT(*) FILTER (WHERE terminal_attribution_version IS NULL) AS unknown_count
        FROM terminal_occurrences
      ) totals
      LEFT JOIN LATERAL (#{queries.join(' UNION ALL ')}) buckets ON TRUE
      ORDER BY buckets.dimension ASC, buckets.outcome ASC, buckets.attribution_state ASC,
        buckets.dimension_id ASC NULLS FIRST
    SQL
  end

  def dimension_aggregate_sql(selected_dimension)
    column = "#{selected_dimension}_id_at_terminal"
    join_sql, catalog_id, name = dimension_join(selected_dimension, "occurrences.#{column}")
    quoted_dimension = connection.quote(selected_dimension)

    <<~SQL.squish
      SELECT #{quoted_dimension} AS dimension, occurrences.stage_outcome AS outcome,
        CASE WHEN occurrences.terminal_attribution_version = 1 THEN occurrences.#{column} END AS dimension_id,
        #{catalog_id} AS catalog_id, #{name} AS dimension_name,
        CASE
          WHEN occurrences.terminal_attribution_version IS NULL THEN 'unknown'
          WHEN occurrences.#{column} IS NULL THEN 'not_configured'
          WHEN #{catalog_id} IS NOT NULL THEN 'current_catalog_projection'
          ELSE 'historical_identity'
        END AS attribution_state,
        CASE WHEN occurrences.terminal_attribution_version = 1 THEN 'exact' ELSE 'unknown' END AS reliability,
        COUNT(*) AS outcome_count
      FROM terminal_occurrences occurrences
      #{join_sql}
      GROUP BY occurrences.stage_outcome, occurrences.terminal_attribution_version,
        occurrences.#{column}, #{catalog_id}, #{name}
    SQL
  end

  def details_sql
    <<~SQL.squish
      WITH terminal_occurrences AS MATERIALIZED (#{filtered_occurrences_sql})
      SELECT page.*, totals.report_total_count, totals.exact_count, totals.unknown_count
      FROM (#{totals_sql}) totals
      LEFT JOIN LATERAL (#{details_page_sql}) page ON TRUE
    SQL
  end

  def totals_sql
    <<~SQL.squish
      SELECT COUNT(*) AS report_total_count,
        COUNT(*) FILTER (WHERE terminal_attribution_version = 1) AS exact_count,
        COUNT(*) FILTER (WHERE terminal_attribution_version IS NULL) AS unknown_count
      FROM terminal_occurrences
    SQL
  end

  def details_page_sql
    <<~SQL.squish
      SELECT occurrences.*,
        owner_memberships.user_id AS owner_catalog_id, owners.name AS owner_name,
        teams.id AS team_catalog_id, teams.name AS team_name
      FROM terminal_occurrences occurrences
      LEFT JOIN account_users owner_memberships
        ON owner_memberships.user_id = occurrences.owner_id_at_terminal
        AND owner_memberships.account_id = #{quoted_account_id}
      LEFT JOIN users owners ON owners.id = owner_memberships.user_id
      LEFT JOIN teams ON teams.id = occurrences.team_id_at_terminal AND teams.account_id = #{quoted_account_id}
      ORDER BY occurrences.entered_at DESC, occurrences.stage_visit_id DESC
      LIMIT #{per_page} OFFSET #{page_offset}
    SQL
  end

  def filtered_occurrences_sql
    predicates = occurrence_predicates
    predicates << "visits.stage_outcome = #{connection.quote(filters[:outcome])}" if filters[:outcome]
    predicates << attribution_filter_predicate('visits.owner_id_at_terminal', filters[:owner_id]) if filters.key?(:owner_id)
    predicates << attribution_filter_predicate('visits.team_id_at_terminal', filters[:team_id]) if filters.key?(:team_id)
    occurrences_sql(predicates)
  end

  def unfiltered_occurrences_sql
    occurrences_sql(occurrence_predicates)
  end

  def occurrences_sql(predicates)
    <<~SQL.squish
      SELECT visits.id AS stage_visit_id, visits.deal_id, visits.pipeline_id, visits.pipeline_name,
        visits.stage_id, visits.stage_name, visits.stage_outcome, visits.entered_at, visits.correlation_id,
        visits.owner_id_at_terminal, visits.team_id_at_terminal, visits.terminal_attribution_version
      FROM crm_stage_visits visits
      INNER JOIN (#{visible_deals_sql}) visible_deals ON visible_deals.id = visits.deal_id
      WHERE #{predicates.join(' AND ')}
    SQL
  end

  def occurrence_predicates
    [
      "visits.account_id = #{quoted_account_id}",
      "visits.stage_outcome IN ('won', 'lost')",
      "visits.entered_at >= #{connection.quote(from_time.utc)}",
      "visits.entered_at < #{connection.quote(to_time.utc)}",
      "visits.entered_at < #{connection.quote(as_of_time.utc)}"
    ]
  end

  def attribution_filter_predicate(column, value)
    case value
    when 'unknown'
      'terminal_attribution_version IS NULL'
    when 'unassigned'
      "terminal_attribution_version = 1 AND #{column} IS NULL"
    else
      "terminal_attribution_version = 1 AND #{column} = #{connection.quote(value)}"
    end
  end

  def aggregate_result
    @aggregate_result ||= result_with_totals(aggregate_sql) do |rows|
      rows.filter_map { |row| aggregate_payload(row) if row['dimension'] }
    end
  end

  def details_result
    @details_result ||= result_with_totals(details_sql) do |rows|
      rows.filter_map { |row| detail_payload(row) if row['stage_visit_id'] }
    end
  end

  def result_with_totals(sql)
    result = connection.exec_query(sql).to_a
    first = result.first
    {
      rows: yield(result),
      total_count: first.fetch('report_total_count').to_i,
      exact_count: first.fetch('exact_count').to_i,
      unknown_count: first.fetch('unknown_count').to_i
    }
  end

  def aggregate_payload(row)
    {
      dimension: row['dimension'],
      outcome: row['outcome'],
      attribution: { id: row['dimension_id'], name: row['dimension_name'], state: row['attribution_state'] },
      outcome_count: row['outcome_count'].to_i,
      reliability: row['reliability']
    }
  end

  def detail_payload(row)
    version = row['terminal_attribution_version']&.to_i
    {
      stage_visit_id: row['stage_visit_id'],
      deal_id: row['deal_id'],
      outcome: row['stage_outcome'],
      entered_at: row['entered_at'].utc.iso8601(6),
      terminal: {
        pipeline_id: row['pipeline_id'], pipeline_name: row['pipeline_name'],
        stage_id: row['stage_id'], stage_name: row['stage_name']
      },
      owner: attribution_payload(version, row['owner_id_at_terminal'], row['owner_catalog_id'], row['owner_name']),
      team: attribution_payload(version, row['team_id_at_terminal'], row['team_catalog_id'], row['team_name']),
      reliability: version == 1 ? 'exact' : 'unknown',
      terminal_attribution_version: version,
      correlation_id: row['correlation_id']
    }
  end

  def attribution_payload(version, raw_id, catalog_id, name)
    return { id: nil, name: nil, state: 'unknown' } unless version == 1
    return { id: nil, name: nil, state: 'not_configured' } if raw_id.blank?

    state = catalog_id.present? ? 'current_catalog_projection' : 'historical_identity'
    { id: raw_id, name: catalog_id.present? ? name : nil, state: state }
  end

  def report_meta(result)
    {
      metric_kind: 'terminal_occurrences',
      reliability: 'row_level',
      coverage: coverage(result),
      global_reliability: 'unknown_until_cutover_recorded',
      exact_count: result.fetch(:exact_count),
      unknown_count: result.fetch(:unknown_count),
      total_count: result.fetch(:total_count),
      **temporal_meta,
      **definition_meta
    }
  end

  def temporal_meta
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

  def definition_meta
    {
      definition_version: 1,
      source_version: 1,
      source: SOURCE,
      query_fingerprint: query_fingerprint,
      occurrence_definition: 'each_won_or_lost_stage_visit_entered_in_workspace_local_half_open_window',
      attribution_definition: 'stage_visit_terminal_snapshot_only_event_actor_and_current_deal_assignment_excluded',
      reliability_definition: 'version_1_is_exact_nil_marker_is_legacy_or_overlap_unknown',
      amount_definition: 'not_reported_not_snapshotted_at_terminal',
      combination_definition: 'owner_and_team_dimensions_must_not_be_summed'
    }
  end

  def coverage(result)
    return 'empty' if result.fetch(:total_count).zero?
    return 'unknown' if result.fetch(:exact_count).zero?
    return 'mixed' if result.fetch(:unknown_count).positive?

    'exact_rows_only'
  end

  def selected_dimensions
    dimension.present? ? [dimension] : DIMENSIONS
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

  def parse_attribution_filter!(key)
    value = params[key].presence&.to_s
    return if value.blank?
    return value if SPECIAL_ATTRIBUTIONS.include?(value)

    parse_positive_integer!(key, value, "#{key} must be a positive integer, unassigned, or unknown")
  end

  def parse_date!(key)
    value = params[key]
    raise_validation!("#{key} is required") if value.blank?
    raise_validation!("#{key} must use YYYY-MM-DD") unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.iso8601(value.to_s)
  rescue Date::Error
    raise_validation!("#{key} must be a valid date")
  end

  def page
    @page ||= parse_positive_integer!(:page, params[:page].presence || 1, 'page must be a positive integer', MAX_PAGE)
  end

  def per_page
    @per_page ||= parse_positive_integer!(:per_page, params[:per_page].presence || DEFAULT_PER_PAGE,
                                          'per_page must be a positive integer', MAX_PER_PAGE)
  end

  def parse_positive_integer!(key, value, message, max = nil)
    raise_validation!(message) unless value.to_s.match?(/\A[1-9]\d*\z/)

    parsed = value.to_i
    raise_validation!("#{key} must not exceed #{max}") if max && parsed > max
    parsed
  end

  def page_offset
    (page - 1) * per_page
  end

  def visible_deals_sql
    deals_scope.where(account_id: account.id).reselect(:id).reorder(nil).to_sql
  end

  def query_fingerprint
    @query_fingerprint ||= Digest::SHA256.hexdigest(
      [QUERY_KIND, account.id, visible_deals_sql, from_time.utc.iso8601(6), to_time.utc.iso8601(6),
       as_of_time.utc.iso8601(6), dimension, filters.sort].to_json
    )
  end

  def quoted_account_id
    connection.quote(account.id)
  end

  def validate_zone!
    raise_validation!('workspace timezone is invalid') if zone.blank?
  end

  def connection
    ActiveRecord::Base.connection
  end

  def raise_validation!(message)
    raise Crm::Error.new(code: 'INVALID_REPORT_QUERY', message: message, status: :unprocessable_content)
  end
end
