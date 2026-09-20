# rubocop:disable Metrics/ClassLength
class Crm::Reports::StageTransitionsQuery
  MAX_WINDOW_DAYS = 366
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100
  FILTER_KEYS = %i[from_pipeline_id from_stage_id pipeline_id stage_id].freeze
  FILTER_COLUMNS = {
    from_pipeline_id: 'from_pipeline_id',
    from_stage_id: 'from_stage_id',
    pipeline_id: 'to_pipeline_id',
    stage_id: 'to_stage_id'
  }.freeze
  GROUP_COLUMNS = %w[
    from_pipeline_id from_pipeline_name from_stage_id from_stage_name from_stage_outcome
    to_pipeline_id to_pipeline_name to_stage_id to_stage_name to_stage_outcome
  ].freeze

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

  def aggregate_rows
    relation.group(*GROUP_COLUMNS).pluck(
      *GROUP_COLUMNS,
      Arel.sql('COUNT(*)'),
      Arel.sql("COUNT(*) FILTER (WHERE reliability = 'exact')"),
      Arel.sql("COUNT(*) FILTER (WHERE reliability = 'estimated')"),
      Arel.sql("COUNT(*) FILTER (WHERE coverage = 'unknown_before')"),
      Arel.sql('MIN(transition_reliable_since)')
    ).map { |values| aggregate_payload(values) }
  end

  def drill_down_rows
    paginated_relation.map { |transition| drill_down_payload(transition) }
  end

  def total_count
    relation.count
  end

  def meta
    earliest_reliable_since = relation.minimum(:transition_reliable_since)
    {
      timezone: timezone,
      from: from_time.utc.iso8601(6),
      to: to_time.utc.iso8601(6),
      reliable_since: earliest_reliable_since&.utc&.iso8601(6),
      coverage: overall_coverage(earliest_reliable_since),
      unknown_before: earliest_reliable_since&.utc&.iso8601(6),
      query_fingerprint: query_fingerprint,
      definition_version: 1,
      source: 'crm_stage_visits'
    }
  end

  def pagination_meta
    meta.merge(page: page, per_page: per_page, total_count: total_count)
  end

  def relation
    @relation ||= Crm::StageVisit.unscoped.from("(#{filtered_sql}) crm_stage_visits")
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
    @filters = FILTER_KEYS.index_with { |key| parse_optional_id!(key) }.compact
    validate_filter_records!
  end

  def parse_optional_id!(key)
    value = params[key]
    return if value.blank?

    raise_validation!("#{key} must be a positive integer") unless value.to_s.match?(/\A[1-9]\d*\z/)

    value.to_i
  end

  def validate_filter_records!
    validate_ids!(:pipeline, %i[from_pipeline_id pipeline_id], account.crm_pipelines)
    validate_ids!(:stage, %i[from_stage_id stage_id], account.crm_stages)
    validate_stage_pipeline_pair!(:from_stage_id, :from_pipeline_id)
    validate_stage_pipeline_pair!(:stage_id, :pipeline_id)
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

  def filtered_sql # rubocop:disable Metrics/MethodLength
    <<~SQL.squish
      WITH ordered_visits AS (
        SELECT
          visits.id AS transition_visit_id,
          visits.deal_id,
          visits.entered_at,
          visits.pipeline_id AS to_pipeline_id,
          visits.pipeline_name AS to_pipeline_name,
          visits.stage_id AS to_stage_id,
          visits.stage_name AS to_stage_name,
          visits.stage_outcome AS to_stage_outcome,
          visits.estimated AS to_estimated,
          visits.reliable_since AS to_reliable_since,
          LAG(visits.id) OVER visit_order AS previous_visit_id,
          LAG(visits.pipeline_id) OVER visit_order AS from_pipeline_id,
          LAG(visits.pipeline_name) OVER visit_order AS from_pipeline_name,
          LAG(visits.stage_id) OVER visit_order AS from_stage_id,
          LAG(visits.stage_name) OVER visit_order AS from_stage_name,
          LAG(visits.stage_outcome) OVER visit_order AS from_stage_outcome,
          LAG(visits.estimated) OVER visit_order AS from_estimated,
          LAG(visits.reliable_since) OVER visit_order AS from_reliable_since
        FROM crm_stage_visits visits
        INNER JOIN (#{visible_deals_sql}) visible_deals ON visible_deals.id = visits.deal_id
        WHERE visits.account_id = #{connection.quote(account.id)}
        WINDOW visit_order AS (PARTITION BY visits.deal_id ORDER BY visits.entered_at ASC, visits.id ASC)
      ), transitions AS (
        SELECT
          ordered_visits.*,
          GREATEST(from_reliable_since, to_reliable_since) AS transition_reliable_since
        FROM ordered_visits
        WHERE previous_visit_id IS NOT NULL
      )
      SELECT
        transitions.transition_visit_id AS id,
        transitions.*,
        CASE
          WHEN from_estimated OR to_estimated THEN 'estimated'
          ELSE 'exact'
        END AS reliability,
        CASE
          WHEN entered_at < transition_reliable_since THEN 'unknown_before'
          WHEN from_estimated OR to_estimated THEN 'estimated'
          ELSE 'exact'
        END AS coverage
      FROM transitions
      WHERE #{filter_predicates.join(' AND ')}
    SQL
  end

  def visible_deals_sql
    deals_scope.reselect(:id).to_sql
  end

  def filter_predicates
    predicates = [
      "entered_at >= #{connection.quote(from_time.utc)}",
      "entered_at < #{connection.quote(to_time.utc)}"
    ]
    predicates + filters.map do |key, value|
      "#{FILTER_COLUMNS.fetch(key)} = #{connection.quote(value)}"
    end
  end

  def aggregate_payload(values)
    dimensions = GROUP_COLUMNS.zip(values.shift(GROUP_COLUMNS.length)).to_h.symbolize_keys
    total_count, exact_count, estimated_count, unknown_count, reliable_since = values
    dimensions.merge(
      total_count: total_count.to_i,
      exact_count: exact_count.to_i,
      estimated_count: estimated_count.to_i,
      reliable_since: reliable_since.utc.iso8601(6),
      coverage: aggregate_coverage(unknown_count.to_i, estimated_count.to_i, reliable_since)
    )
  end

  def aggregate_coverage(unknown_count, estimated_count, reliable_since)
    return 'unknown_before' if unknown_count.positive? || from_time < reliable_since
    return 'estimated' if estimated_count.positive?

    'exact'
  end

  def drill_down_payload(transition)
    {
      transition_visit_id: transition.transition_visit_id,
      deal_id: transition.deal_id,
      entered_at: transition.entered_at.utc.iso8601(6),
      from: snapshot_payload(transition, :from),
      to: snapshot_payload(transition, :to),
      reliability: transition.reliability,
      reliable_since: transition.transition_reliable_since.utc.iso8601(6),
      coverage: transition.coverage
    }
  end

  def snapshot_payload(transition, direction)
    {
      pipeline_id: transition.public_send("#{direction}_pipeline_id"),
      pipeline_name: transition.public_send("#{direction}_pipeline_name"),
      stage_id: transition.public_send("#{direction}_stage_id"),
      stage_name: transition.public_send("#{direction}_stage_name"),
      stage_outcome: transition.public_send("#{direction}_stage_outcome")
    }
  end

  def paginated_relation
    relation.order(entered_at: :desc, id: :desc).offset((page - 1) * per_page).limit(per_page)
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

  def overall_coverage(earliest_reliable_since)
    return 'unknown_before' if earliest_reliable_since.blank? || from_time < earliest_reliable_since
    return 'estimated' if relation.exists?(reliability: 'estimated')

    'exact'
  end

  def query_fingerprint
    @query_fingerprint ||= Digest::SHA256.hexdigest(
      [account.id, visible_deals_sql, from_time.utc.iso8601(6), to_time.utc.iso8601(6), filters.sort].to_json
    )
  end

  def connection
    ActiveRecord::Base.connection
  end

  def raise_validation!(message)
    raise Crm::Error.new(code: 'INVALID_REPORT_QUERY', message: message, status: :unprocessable_content)
  end
end
# rubocop:enable Metrics/ClassLength
