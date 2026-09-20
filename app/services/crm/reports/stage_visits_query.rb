class Crm::Reports::StageVisitsQuery
  MAX_WINDOW_DAYS = 366
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100

  attr_reader :account, :deals_scope, :params, :timezone, :from_time, :to_time

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

  private

  attr_reader :zone, :filters

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

  def parse_date!(key)
    value = params[key]
    raise_validation!("#{key} is required") if value.blank?
    raise_validation!("#{key} must use YYYY-MM-DD") unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.iso8601(value.to_s)
  rescue Date::Error
    raise_validation!("#{key} must be a valid date")
  end

  def normalize_filters!
    @filters = self.class::FILTER_KEYS.index_with { |key| parse_optional_id!(key) }.compact
    validate_filter_records!
  end

  def parse_optional_id!(key)
    value = params[key]
    return if value.blank?

    raise_validation!("#{key} must be a positive integer") unless value.to_s.match?(/\A[1-9]\d*\z/)

    value.to_i
  end

  def validate_filter_records!
    validate_ids!(:pipeline, pipeline_filter_keys, account.crm_pipelines)
    validate_ids!(:stage, stage_filter_keys, account.crm_stages)
    filter_pairs.each { |stage_key, pipeline_key| validate_stage_pipeline_pair!(stage_key, pipeline_key) }
  end

  def pipeline_filter_keys
    self.class::FILTER_KEYS.select { |key| key.to_s.end_with?('pipeline_id') }
  end

  def stage_filter_keys
    self.class::FILTER_KEYS.select { |key| key.to_s.end_with?('stage_id') }
  end

  def filter_pairs
    [[:stage_id, :pipeline_id], [:from_stage_id, :from_pipeline_id]].select do |stage_key, pipeline_key|
      self.class::FILTER_KEYS.include?(stage_key) && self.class::FILTER_KEYS.include?(pipeline_key)
    end
  end

  def validate_ids!(label, keys, scope)
    requested_ids = filters.values_at(*keys).compact.uniq
    return if requested_ids.empty? || scope.where(id: requested_ids).count == requested_ids.length

    raise_validation!("#{label} filter is invalid")
  end

  def validate_stage_pipeline_pair!(stage_key, pipeline_key)
    return if filters[stage_key].blank? || filters[pipeline_key].blank?
    return if account.crm_stages.exists?(id: filters[stage_key], pipeline_id: filters[pipeline_key])

    raise_validation!("#{stage_key} does not belong to #{pipeline_key}")
  end

  def validate_zone!
    raise_validation!('workspace timezone is invalid') if zone.blank?
  end

  def visible_deals_sql
    deals_scope.reselect(:id).to_sql
  end

  def filter_predicates
    filters.map do |key, value|
      "#{self.class::FILTER_COLUMNS.fetch(key)} = #{connection.quote(value)}"
    end
  end

  def base_meta(reliable_since:, coverage:)
    {
      timezone: timezone,
      from: from_time.utc.iso8601(6),
      to: to_time.utc.iso8601(6),
      from_local: from_time.iso8601(6),
      to_local: to_time.iso8601(6),
      reliable_since: reliable_since&.utc&.iso8601(6),
      coverage: coverage,
      unknown_before: reliable_since&.utc&.iso8601(6),
      query_fingerprint: query_fingerprint,
      definition_version: 1,
      source: 'crm_stage_visits'
    }
  end

  def paginated_relation(relation, order:)
    relation.order(order).offset((page - 1) * per_page).limit(per_page)
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
      [self.class::QUERY_KIND, account.id, visible_deals_sql, from_time.utc.iso8601(6), to_time.utc.iso8601(6), filters.sort].to_json
    )
  end

  def connection
    ActiveRecord::Base.connection
  end

  def raise_validation!(message)
    raise Crm::Error.new(code: 'INVALID_REPORT_QUERY', message: message, status: :unprocessable_content)
  end
end
