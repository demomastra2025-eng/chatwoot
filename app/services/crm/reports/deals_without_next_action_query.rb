class Crm::Reports::DealsWithoutNextActionQuery
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100
  MAX_PAGE = 10_000
  QUERY_KIND = 'deals_without_next_action'.freeze
  SOURCE = 'crm_deals+crm_tasks+crm_task_statuses'.freeze
  OPEN_TASK_CATEGORIES = %w[open in_progress].freeze
  FILTER_KEYS = %i[pipeline_id stage_id owner_id team_id].freeze
  attr_reader :account, :generated_at, :params, :timezone

  def initialize(account:, deals_scope:, tasks_scope:, params: {}, generated_at: Time.current)
    @account = account
    @deals_scope = deals_scope
    @tasks_scope = tasks_scope
    @params = params.to_h.symbolize_keys
    @generated_at = generated_at
    @timezone = account.workspace_working_hours_timezone
    normalize_filters!
  end

  def aggregate_rows
    [{ no_action_count: total_count }]
  end

  def drill_down_rows = details_result.fetch(:rows)

  def total_count = relation.count

  def meta
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
      metric_definition: 'open_kept_visible_deals_without_waiting_or_visible_open_or_in_progress_kept_task',
      cohort_definition: 'deal_view_intersect_view_reports_open_kept_at_generated_at',
      action_definition: 'waiting_including_expired_or_task_view_intersect_view_reports_open_or_in_progress_kept',
      temporal_definition: 'exact_current_snapshot_not_historical'
    }
  end

  def pagination_meta
    details_count = details_result.fetch(:total_count)
    meta.merge(page: page, per_page: per_page, total_count: details_count)
  end

  def relation
    @relation ||= begin
      scope = deals_scope.where(account_id: account.id, archived_at: nil, closed_at: nil, waiting_until: nil)
      filters.each { |key, value| scope = scope.where(key => value) }
      scope
        .where("NOT EXISTS (#{visible_action_tasks_sql})")
        .joins(tenant_dimension_join('INNER JOIN crm_pipelines pipelines', 'pipelines', 'crm_deals.pipeline_id'))
        .joins(tenant_dimension_join('INNER JOIN crm_stages stages', 'stages', 'crm_deals.stage_id'))
    end
  end

  private

  attr_reader :deals_scope, :tasks_scope, :filters

  def normalize_filters!
    @filters = FILTER_KEYS.index_with { |key| parse_optional_positive_integer!(key) }.compact
    validate_filter_records!
  end

  def validate_filter_records!
    validate_filter!(:pipeline_id, account.crm_pipelines)
    validate_filter!(:stage_id, account.crm_stages)
    validate_filter!(:owner_id, account.users)
    validate_filter!(:team_id, account.teams)

    return unless filters[:pipeline_id] && filters[:stage_id]
    return if account.crm_stages.exists?(id: filters[:stage_id], pipeline_id: filters[:pipeline_id])

    raise_validation!('stage_id does not belong to pipeline_id')
  end

  def validate_filter!(key, scope)
    return unless filters[key]
    return if scope.exists?(id: filters[key])

    raise_validation!("#{key} is invalid")
  end

  def visible_action_tasks_sql
    tasks_scope
      .where(account_id: account.id, archived_at: nil)
      .joins(:status)
      .where(crm_task_statuses: { account_id: account.id, category: OPEN_TASK_CATEGORIES })
      .where('crm_tasks.deal_id = crm_deals.id')
      .select('1')
      .reorder(nil)
      .to_sql
  end

  def details_result
    @details_result ||= begin
      result = ActiveRecord::Base.connection.exec_query(details_sql).to_a
      {
        rows: result.filter_map { |row| drill_down_payload(row) if row['deal_id'] },
        total_count: result.first.fetch('report_total_count').to_i
      }
    end
  end

  def details_sql
    <<~SQL.squish
      WITH matching_deals AS MATERIALIZED (#{details_relation.to_sql})
      SELECT page.*, totals.report_total_count
      FROM (SELECT COUNT(*) AS report_total_count FROM matching_deals) totals
      LEFT JOIN LATERAL (
        SELECT deals.deal_id, deals.title, deals.expected_close_on,
          deals.pipeline_id, deals.pipeline_name, deals.pipeline_code,
          deals.stage_id, deals.stage_name, deals.stage_code,
          owners.id AS owner_id, owners.name AS owner_name,
          teams.id AS team_id, teams.name AS team_name
        FROM (SELECT * FROM matching_deals ORDER BY deal_id ASC LIMIT #{per_page} OFFSET #{page_offset}) deals
        #{owner_membership_join('deals.deal_owner_id')}
        LEFT JOIN users owners ON owners.id = owner_memberships.user_id
        #{tenant_dimension_join('LEFT JOIN teams', 'teams', 'deals.deal_team_id')}
        ORDER BY deals.deal_id ASC
      ) page ON TRUE
    SQL
  end

  def details_relation
    relation
      .reselect(
        'crm_deals.id AS deal_id', 'crm_deals.title', 'crm_deals.expected_close_on',
        'crm_deals.owner_id AS deal_owner_id', 'crm_deals.team_id AS deal_team_id',
        'pipelines.id AS pipeline_id', 'pipelines.name AS pipeline_name', 'pipelines.code AS pipeline_code',
        'stages.id AS stage_id', 'stages.name AS stage_name', 'stages.code AS stage_code'
      )
      .reorder(nil)
  end

  def owner_membership_join(foreign_key)
    ActiveRecord::Base.sanitize_sql_array(
      ["LEFT JOIN account_users owner_memberships ON owner_memberships.user_id = #{foreign_key} AND owner_memberships.account_id = ?", account.id]
    )
  end

  def tenant_dimension_join(join_clause, table, foreign_key)
    ActiveRecord::Base.sanitize_sql_array(
      ["#{join_clause} ON #{table}.id = #{foreign_key} AND #{table}.account_id = ?", account.id]
    )
  end

  def drill_down_payload(row)
    {
      deal_id: row['deal_id'],
      title: row['title'],
      pipeline: catalog_payload(row, :pipeline),
      stage: catalog_payload(row, :stage),
      owner: principal_payload(row, :owner),
      team: principal_payload(row, :team),
      expected_close_on: row['expected_close_on']&.iso8601
    }
  end

  def catalog_payload(row, prefix)
    { id: row["#{prefix}_id"], name: row["#{prefix}_name"], code: row["#{prefix}_code"] }
  end

  def principal_payload(row, prefix)
    return if row["#{prefix}_id"].blank?

    { id: row["#{prefix}_id"], name: row["#{prefix}_name"] }
  end

  def page
    @page ||= parse_positive_integer!(:page, default: 1, max: MAX_PAGE)
  end

  def per_page
    @per_page ||= parse_positive_integer!(:per_page, default: DEFAULT_PER_PAGE, max: MAX_PER_PAGE)
  end

  def page_offset = (page - 1) * per_page

  def parse_optional_positive_integer!(key)
    return if params[key].blank?

    parse_positive_integer!(key, default: nil)
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
      [QUERY_KIND, account.id, deals_scope.to_sql, tasks_scope.to_sql, filters.sort].to_json
    )
  end

  def raise_validation!(message)
    raise Crm::Error.new(code: 'INVALID_REPORT_QUERY', message: message, status: :unprocessable_content)
  end
end
