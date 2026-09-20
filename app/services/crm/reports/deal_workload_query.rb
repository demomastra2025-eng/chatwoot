class Crm::Reports::DealWorkloadQuery # rubocop:disable Metrics/ClassLength
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100
  MAX_PAGE = 10_000
  DIMENSIONS = %w[owner team].freeze
  QUERY_KIND = 'deal_workload'.freeze
  SOURCE = 'crm_deals'.freeze
  UNASSIGNED = 'unassigned'.freeze

  attr_reader :account, :dimension, :generated_at, :params, :timezone

  def initialize(account:, deals_scope:, params: {}, generated_at: Time.current)
    @account = account
    @deals_scope = deals_scope
    @params = params.to_h.symbolize_keys
    @generated_at = generated_at
    @timezone = account.workspace_working_hours_timezone
    reject_historical_query!
    normalize_filters!
  end

  def aggregate_rows
    aggregate_result.fetch(:rows)
  end

  def drill_down_rows = details_result.fetch(:rows)

  def meta
    report_meta.merge(total_count: aggregate_result.fetch(:total_count))
  end

  def pagination_meta
    report_meta.merge(page: page, per_page: per_page, total_count: details_result.fetch(:total_count))
  end

  def relation
    @relation ||= begin
      scope = deals_scope.where(account_id: account.id, archived_at: nil, closed_at: nil)
      scope = scope.joins(tenant_catalog_join('crm_pipelines', 'workload_pipelines', 'pipeline_id'))
                   .joins(tenant_catalog_join('crm_stages', 'workload_stages', 'stage_id'))
      scope = scope.where(crm_deals: { pipeline_id: filters[:pipeline_id] }) if filters.key?(:pipeline_id)
      scope = scope.where(crm_deals: { stage_id: filters[:stage_id] }) if filters.key?(:stage_id)
      scope = apply_attribution_filter(scope, :owner_id)
      apply_attribution_filter(scope, :team_id)
    end
  end

  private

  attr_reader :deals_scope, :filters

  def reject_historical_query!
    unsupported = %i[from to as_of from_date to_date as_of_date].find { |key| params[key].present? }
    raise_validation!("#{unsupported} is not supported for current snapshots") if unsupported
  end

  def normalize_filters!
    @dimension = params[:dimension].presence&.to_s
    raise_validation!('dimension must be owner or team') if dimension.present? && DIMENSIONS.exclude?(dimension)

    @filters = normalized_filter_values
    validate_filters!
  end

  def validate_filters!
    validate_dimension_filters!
    validate_filter!(:pipeline_id, account.crm_pipelines)
    validate_filter!(:stage_id, account.crm_stages)
    validate_attribution_filter!(:owner_id, account.users)
    validate_attribution_filter!(:team_id, account.teams)
    validate_pipeline_stage!
  end

  def normalized_filter_values
    {
      pipeline_id: parse_optional_positive_integer!(:pipeline_id),
      stage_id: parse_optional_positive_integer!(:stage_id),
      owner_id: parse_attribution_filter!(:owner_id),
      team_id: parse_attribution_filter!(:team_id)
    }.compact
  end

  def validate_pipeline_stage!
    return unless filters[:pipeline_id] && filters[:stage_id]
    return if account.crm_stages.exists?(id: filters[:stage_id], pipeline_id: filters[:pipeline_id])

    raise_validation!('stage_id does not belong to pipeline_id')
  end

  def validate_dimension_filters!
    raise_validation!('dimension=owner is required with owner_id') if filters.key?(:owner_id) && dimension != 'owner'
    raise_validation!('dimension=team is required with team_id') if filters.key?(:team_id) && dimension != 'team'
  end

  def validate_filter!(key, scope)
    return unless filters[key]
    return if scope.exists?(id: filters[key])

    raise_validation!("#{key} is invalid")
  end

  def validate_attribution_filter!(key, catalog_scope)
    return unless filters.key?(key)

    value = filters[key] == UNASSIGNED ? nil : filters[key]
    valid_catalog = value.nil? || catalog_scope.exists?(id: value)
    valid_visible_attribution = deals_scope.where(account_id: account.id).exists?(key => value)
    raise_validation!("#{key} is invalid") unless valid_catalog && valid_visible_attribution
  end

  def apply_attribution_filter(scope, key)
    return scope unless filters.key?(key)

    value = filters[key] == UNASSIGNED ? nil : filters[key]
    scope.where(crm_deals: { key => value })
  end

  def aggregate_sql
    queries = selected_dimensions.map { |selected_dimension| dimension_aggregate_sql(selected_dimension) }
    <<~SQL.squish
      WITH matching_deals AS MATERIALIZED (#{report_relation.to_sql})
      SELECT buckets.*, totals.report_total_count
      FROM (SELECT COUNT(*) AS report_total_count FROM matching_deals) totals
      LEFT JOIN LATERAL (#{queries.join(' UNION ALL ')}) buckets ON TRUE
      ORDER BY buckets.dimension ASC, buckets.dimension_id ASC NULLS FIRST
    SQL
  end

  def dimension_aggregate_sql(selected_dimension)
    foreign_key = "deal_#{selected_dimension}_id"
    join_sql, catalog_id, name = dimension_join(selected_dimension, "deals.#{foreign_key}")
    quoted_dimension = ActiveRecord::Base.connection.quote(selected_dimension)

    <<~SQL.squish
      SELECT #{quoted_dimension} AS dimension, deals.#{foreign_key} AS dimension_id,
        #{catalog_id} AS catalog_id, #{name} AS dimension_name,
        COUNT(*) AS open_count,
        COUNT(*) FILTER (WHERE deals.waiting_until IS NOT NULL) AS waiting_count,
        COUNT(*) FILTER (WHERE deals.waiting_until IS NULL) AS actionable_count
      FROM matching_deals deals
      #{join_sql}
      GROUP BY deals.#{foreign_key}, #{catalog_id}, #{name}
    SQL
  end

  def details_sql
    <<~SQL.squish
      WITH matching_deals AS MATERIALIZED (#{report_relation.to_sql})
      SELECT page.*, totals.report_total_count
      FROM (SELECT COUNT(*) AS report_total_count FROM matching_deals) totals
      LEFT JOIN LATERAL (
        SELECT deals.*,
          owner_memberships.user_id AS owner_catalog_id, owners.name AS owner_name,
          teams.id AS team_catalog_id, teams.name AS team_name
        FROM matching_deals deals
        LEFT JOIN account_users owner_memberships
          ON owner_memberships.user_id = deals.deal_owner_id AND owner_memberships.account_id = #{quoted_account_id}
        LEFT JOIN users owners ON owners.id = owner_memberships.user_id
        LEFT JOIN teams ON teams.id = deals.deal_team_id AND teams.account_id = #{quoted_account_id}
        ORDER BY deals.deal_id ASC
        LIMIT #{per_page} OFFSET #{page_offset}
      ) page ON TRUE
    SQL
  end

  def report_relation
    relation.reselect(
      'crm_deals.id AS deal_id', 'crm_deals.title', 'crm_deals.expected_close_on',
      'crm_deals.owner_id AS deal_owner_id', 'crm_deals.team_id AS deal_team_id',
      'crm_deals.pipeline_id AS deal_pipeline_id', 'crm_deals.stage_id AS deal_stage_id',
      'crm_deals.waiting_until', 'crm_deals.waiting_reason'
    ).reorder(nil)
  end

  def details_result
    @details_result ||= begin
      result = ActiveRecord::Base.connection.exec_query(details_sql).to_a
      {
        rows: result.filter_map { |row| detail_payload(row) if row['deal_id'] },
        total_count: result.first.fetch('report_total_count').to_i
      }
    end
  end

  def aggregate_result
    @aggregate_result ||= begin
      result = ActiveRecord::Base.connection.exec_query(aggregate_sql).to_a
      {
        rows: result.filter_map { |row| aggregate_payload(row) if row['dimension'] },
        total_count: result.first.fetch('report_total_count').to_i
      }
    end
  end

  def aggregate_payload(row)
    selected_dimension = row['dimension']
    {
      dimension: selected_dimension,
      attribution: attribution_payload(
        raw_id: row['dimension_id'],
        catalog_id: row['catalog_id'],
        name: row['dimension_name']
      ),
      open_count: row['open_count'].to_i,
      waiting_count: row['waiting_count'].to_i,
      actionable_count: row['actionable_count'].to_i
    }
  end

  def detail_payload(row)
    {
      deal_id: row['deal_id'],
      title: row['title'],
      owner: attribution_payload(raw_id: row['deal_owner_id'], catalog_id: row['owner_catalog_id'], name: row['owner_name']),
      team: attribution_payload(raw_id: row['deal_team_id'], catalog_id: row['team_catalog_id'], name: row['team_name']),
      pipeline_id: row['deal_pipeline_id'],
      stage_id: row['deal_stage_id'],
      expected_close_on: row['expected_close_on']&.iso8601,
      state: row['waiting_until'].present? ? 'waiting' : 'actionable',
      waiting_until: row['waiting_until']&.iso8601(6),
      waiting_reason: row['waiting_reason']
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

  def tenant_catalog_join(table, alias_name, foreign_key)
    "INNER JOIN #{table} #{alias_name} ON #{alias_name}.id = crm_deals.#{foreign_key} " \
      "AND #{alias_name}.account_id = #{quoted_account_id}"
  end

  def report_meta
    {
      metric_kind: 'current_snapshot',
      reliability: 'exact',
      generated_at: generated_at.utc.iso8601(6),
      generated_at_local: generated_at.in_time_zone(timezone).iso8601(6),
      timezone: timezone,
      definition_version: 1,
      source_version: 1,
      source: SOURCE,
      query_fingerprint: query_fingerprint,
      cohort_definition: 'deal_view_intersect_view_reports_open_unarchived_at_generated_at',
      state_definition: 'waiting_when_waiting_until_is_present_including_expired_otherwise_actionable',
      attribution_definition: 'persisted_owner_and_team_are_independent_dimensions_current_catalog_labels_do_not_rewrite_attribution',
      temporal_definition: 'exact_current_snapshot_not_historical',
      historical_attribution: 'unknown_not_supported',
      combination_definition: 'owner_and_team_dimensions_must_not_be_summed'
    }
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

  def query_fingerprint
    @query_fingerprint ||= Digest::SHA256.hexdigest(
      [QUERY_KIND, account.id, deals_scope.to_sql, dimension, filters.sort].to_json
    )
  end

  def quoted_account_id = ActiveRecord::Base.connection.quote(account.id)

  def raise_validation!(message)
    raise Crm::Error.new(code: 'INVALID_REPORT_QUERY', message: message, status: :unprocessable_content)
  end
end
