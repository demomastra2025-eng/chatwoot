class Crm::Reports::DealsWithoutNextActionQuery
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100
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

  def drill_down_rows
    paginated_relation.preload(:pipeline, :stage, :owner, :team).map { |deal| drill_down_payload(deal) }
  end

  def total_count
    relation.count
  end

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
    meta.merge(page: page, per_page: per_page, total_count: total_count)
  end

  def relation
    @relation ||= begin
      scope = deals_scope.where(account_id: account.id, archived_at: nil, closed_at: nil, waiting_until: nil)
      filters.each { |key, value| scope = scope.where(key => value) }
      scope.where("NOT EXISTS (#{visible_action_tasks_sql})")
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

  def paginated_relation
    relation.reorder(id: :asc).offset((page - 1) * per_page).limit(per_page)
  end

  def drill_down_payload(deal)
    {
      deal_id: deal.id,
      title: deal.title,
      pipeline: catalog_payload(deal.pipeline),
      stage: catalog_payload(deal.stage),
      owner: principal_payload(deal.owner),
      team: principal_payload(deal.team),
      expected_close_on: deal.expected_close_on&.iso8601
    }
  end

  def catalog_payload(record)
    { id: record.id, name: record.name, code: record.code }
  end

  def principal_payload(record)
    return if record.blank?

    { id: record.id, name: record.name }
  end

  def page
    @page ||= parse_positive_integer!(:page, default: 1)
  end

  def per_page
    @per_page ||= parse_positive_integer!(:per_page, default: DEFAULT_PER_PAGE, max: MAX_PER_PAGE)
  end

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
