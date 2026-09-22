require 'digest'
require 'json'

class Telephony::Reports::LogicalCallsQuery # rubocop:disable Metrics/ClassLength
  DEFAULT_LONG_THRESHOLD_SECONDS = 25
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100
  MAX_PAGE = 10_000
  MAX_WINDOW_SECONDS = 366.days.to_i
  LOCAL_DATETIME_PATTERN = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d{1,6})?\z/
  RFC3339_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/
  QUERY_KIND = 'telephony_logical_calls'.freeze
  METRICS = %w[attempted connected terminal long].freeze
  DIMENSIONS = %w[actor team assistant provider inbox].freeze

  DIMENSION_COLUMNS = {
    'actor' => %w[actor_kind actor_id_snapshot actor_name_snapshot],
    'team' => %w[actor_team_id_snapshot actor_team_name_snapshot],
    'assistant' => %w[assistant_id_snapshot assistant_name_snapshot],
    'provider' => %w[provider],
    'inbox' => %w[inbox_id_snapshot]
  }.freeze
  FILTER_COLUMNS = {
    direction: :direction,
    provider: :provider,
    inbox_id: :inbox_id_snapshot,
    actor_kind: :actor_kind,
    actor_id: :actor_id_snapshot,
    actor_team_id: :actor_team_id_snapshot,
    assistant_id: :assistant_id_snapshot,
    terminal_status: :terminal_status,
    reliability: :reliability
  }.freeze

  attr_reader :account, :as_of, :from_time, :params, :timezone, :to_time

  def initialize(account:, occurrences_scope:, params: {})
    @account = account
    @occurrences_scope = occurrences_scope
    @params = params.to_h.symbolize_keys
    @timezone = account.workspace_working_hours_timezone
    normalize_window!
    normalize_as_of!
    normalize_query!
  end

  def aggregate_rows
    return [] unless configured?

    @aggregate_rows ||= aggregate_metrics.flat_map { |metric_name| aggregate_metric(metric_name) }
  end

  def drill_down_rows
    details_result.fetch(:rows)
  end

  def meta
    observed_count = aggregate_rows.sum { |row| row[:total_count] }
    report_meta.merge(total_count: count_or_unknown(observed_count), observed_count: observed_count)
  end

  def pagination_meta
    observed_count = details_result.fetch(:total_count)
    report_meta.merge(
      page: page,
      per_page: per_page,
      total_count: count_or_unknown(observed_count),
      observed_count: observed_count
    )
  end

  def relation_for(metric_name)
    metric_relation(metric_name)
  end

  private

  attr_reader :dimension, :filters, :long_threshold_seconds, :metric, :occurrences_scope

  def normalize_window!
    zone = ActiveSupport::TimeZone[timezone]
    @from_time = parse_local_time!(zone, :from_local)
    @to_time = parse_local_time!(zone, :to_local)
    raise_validation!('to_local must be after from_local') unless to_time > from_time
    raise_validation!('window must not exceed 366 days') if to_time - from_time > MAX_WINDOW_SECONDS
  end

  def normalize_as_of!
    value = params[:as_of]
    raise_validation!('as_of is required') if value.blank?
    raise_validation!('as_of must be an RFC3339 instant') unless value.is_a?(String) && RFC3339_PATTERN.match?(value)

    @as_of = Time.iso8601(value).utc
    raise_validation!('as_of must not be in the future') if @as_of > Time.current
  rescue ArgumentError
    raise_validation!('as_of must be an RFC3339 instant')
  end

  def normalize_query!
    @metric = params[:metric].presence&.to_s
    raise_validation!('metric is invalid') if metric.present? && METRICS.exclude?(metric)

    @dimension = params[:dimension].presence&.to_s || 'actor'
    raise_validation!('dimension is invalid') unless DIMENSIONS.include?(dimension)

    @long_threshold_seconds = parse_positive_integer!(
      :long_threshold_seconds,
      default: DEFAULT_LONG_THRESHOLD_SECONDS,
      max: 86_400
    )
    @filters = normalize_filters
    validate_filter_ids_if_configured!
  end

  def validate_filter_ids_if_configured!
    validate_filter_ids! if configured?
  end

  def normalize_filters
    values = {}
    values[:direction] = normalize_enum(:direction, Telephony::CallSession::ALLOWED_DIRECTIONS)
    values[:actor_kind] = normalize_enum(:actor_kind, Telephony::LogicalCallOccurrence::ACTOR_KINDS)
    values[:reliability] = normalize_enum(:reliability, %w[exact unknown])
    values[:provider] = normalize_string(:provider)
    values[:terminal_status] = normalize_string(:terminal_status)
    %i[inbox_id actor_id actor_team_id assistant_id].each do |key|
      values[key] = parse_optional_positive_integer!(key)
    end
    values.compact
  end

  def normalize_enum(key, allowed)
    value = normalize_string(key)
    return if value.blank?

    raise_validation!("#{key} is invalid") unless allowed.include?(value)

    value
  end

  def normalize_string(key)
    return if params[key].blank?

    value = params[key].to_s.strip
    raise_validation!("#{key} is invalid") if value.blank?
    value
  end

  def validate_filter_ids!
    relation = windowed_current_occurrences
    {
      inbox_id: :inbox_id_snapshot,
      actor_id: :actor_id_snapshot,
      actor_team_id: :actor_team_id_snapshot,
      assistant_id: :assistant_id_snapshot
    }.each do |filter_key, column|
      next unless filters[filter_key]

      raise_validation!("#{filter_key} is invalid") unless relation.exists?(column => filters[filter_key])
    end
    %i[provider terminal_status].each do |key|
      next unless filters[key]

      raise_validation!("#{key} is invalid") unless relation.exists?(key => filters[key])
    end
  end

  def configured?
    @configured ||= account.inboxes.exists?(channel_type: 'Channel::Voice')
  end

  def current_occurrences
    @current_occurrences ||= occurrences_scope
                             .where(account_id: account.id)
                             .where('telephony_logical_call_occurrences.created_at <= ?', as_of)
                             .where(<<~SQL.squish, as_of)
                               NOT EXISTS (
                                 SELECT 1 FROM telephony_logical_call_occurrences successors
                                 WHERE successors.supersedes_occurrence_id = telephony_logical_call_occurrences.id
                                   AND successors.created_at <= ?
                               )
                             SQL
  end

  def windowed_current_occurrences
    @windowed_current_occurrences ||= current_occurrences
                                      .where(occurred_at: from_time...to_time)
  end

  def filtered_occurrences
    @filtered_occurrences ||= filters.reduce(windowed_current_occurrences) do |relation, (key, value)|
      relation.where(FILTER_COLUMNS.fetch(key) => value)
    end
  end

  def metric_relation(metric_name)
    relation = filtered_occurrences.where(occurrence_kind: metric_name == 'long' ? 'terminal' : metric_name)
    return relation unless metric_name == 'long'

    exact = relation.where(reliability: 'exact').where('duration_seconds >= ?', long_threshold_seconds)
    exact.or(relation.where(reliability: 'unknown'))
  end

  def aggregate_metrics
    metric.present? ? [metric] : METRICS
  end

  def aggregate_metric(metric_name)
    columns = DIMENSION_COLUMNS.fetch(dimension)
    rows = grouped_reliability_counts(metric_name, columns).map do |values, reliability_counts|
      exact_count = reliability_counts['exact'].to_i
      unknown_count = reliability_counts['unknown'].to_i
      {
        metric: metric_name,
        dimension: dimension,
        bucket: dimension_payload(columns, values),
        exact_count: exact_count,
        unknown_count: unknown_count,
        total_count: exact_count + unknown_count
      }
    end
    rows.sort_by { |row| JSON.generate(row[:bucket]) }
  end

  def grouped_reliability_counts(metric_name, columns)
    counts = metric_relation(metric_name).group(*columns, :reliability).distinct.count(:logical_call_identity)
    counts.each_with_object({}) do |(key, count), memo|
      values = Array(key)
      reliability = values.pop
      memo[values] ||= Hash.new(0)
      memo[values][reliability] += count
    end
  end

  def dimension_payload(columns, values) # rubocop:disable Metrics/CyclomaticComplexity
    attributes = columns.zip(values).to_h
    case dimension
    when 'actor'
      snapshot_payload(attributes, kind_key: 'actor_kind', id_key: 'actor_id_snapshot', name_key: 'actor_name_snapshot')
    when 'team'
      snapshot_payload(attributes, id_key: 'actor_team_id_snapshot', name_key: 'actor_team_name_snapshot')
    when 'assistant'
      snapshot_payload(attributes, id_key: 'assistant_id_snapshot', name_key: 'assistant_name_snapshot')
    when 'provider'
      { value: attributes['provider'], state: attributes['provider'].present? ? 'exact' : 'unknown' }
    when 'inbox'
      { id: attributes['inbox_id_snapshot'], state: attributes['inbox_id_snapshot'].present? ? 'captured' : 'not_configured' }
    end
  end

  def snapshot_payload(attributes, id_key:, name_key:, kind_key: nil)
    id = attributes[id_key]
    name = attributes[name_key]
    state = if id.present? || name.present?
              'captured'
            elsif kind_key && attributes[kind_key].present?
              attributes[kind_key] == 'unknown' ? 'unknown' : 'not_configured'
            else
              'not_configured'
            end
    { kind: kind_key ? attributes[kind_key] : nil, id: id, name: name, state: state }.compact
  end

  def details_result
    @details_result ||= begin
      metric_name = required_details_metric!
      relation = metric_relation(metric_name)
      rows = relation.order(occurred_at: :desc, id: :desc).limit(per_page).offset(page_offset)
      { rows: rows.map { |occurrence| detail_payload(occurrence, metric_name) }, total_count: relation.distinct.count(:logical_call_identity) }
    end
  end

  def detail_payload(occurrence, metric_name)
    {
      occurrence_id: occurrence.id,
      logical_call_identity: occurrence.logical_call_identity,
      logical_call_ref: occurrence.logical_call_ref,
      metric: metric_name,
      provider: occurrence.provider,
      direction: occurrence.direction,
      inbox_id_snapshot: occurrence.inbox_id_snapshot,
      actor: actor_snapshot(occurrence),
      assistant: assistant_snapshot(occurrence)
    }.merge(detail_timestamps(occurrence), detail_outcome(occurrence))
  end

  def detail_timestamps(occurrence)
    {
      occurred_at: occurrence.occurred_at.utc.iso8601(6),
      occurred_at_local: occurrence.occurred_at.in_time_zone(timezone).iso8601(6),
      connected_at: occurrence.connected_at&.utc&.iso8601(6),
      terminal_at: occurrence.terminal_at&.utc&.iso8601(6),
      reliable_since: occurrence.reliable_since.utc.iso8601(6)
    }
  end

  def detail_outcome(occurrence)
    {
      duration_seconds: occurrence.duration_seconds,
      terminal_status: occurrence.terminal_status,
      terminal_reason: occurrence.terminal_reason,
      reliability: occurrence.reliability,
      source_version: occurrence.source_version,
      definition_version: occurrence.definition_version
    }
  end

  def actor_snapshot(occurrence)
    {
      kind: occurrence.actor_kind,
      id: occurrence.actor_id_snapshot,
      name: occurrence.actor_name_snapshot,
      team_id: occurrence.actor_team_id_snapshot,
      team_name: occurrence.actor_team_name_snapshot
    }
  end

  def assistant_snapshot(occurrence)
    { id: occurrence.assistant_id_snapshot, name: occurrence.assistant_name_snapshot }
  end

  def required_details_metric!
    raise_validation!('metric is required for details') if metric.blank?

    metric
  end

  def report_meta
    {
      state: configured? ? 'ready' : 'not_configured',
      coverage_state: coverage_state,
      exact_zero_supported: false,
      timezone: timezone,
      from: from_time.utc.iso8601(6),
      to: to_time.utc.iso8601(6),
      from_local: from_time.in_time_zone(timezone).iso8601(6),
      to_local: to_time.in_time_zone(timezone).iso8601(6),
      as_of: as_of.iso8601(6),
      dimension: dimension,
      metric: metric,
      long_threshold_seconds: long_threshold_seconds,
      query_fingerprint: query_fingerprint,
      definition_version: 1,
      source_version: 1,
      source: 'telephony_logical_call_occurrences',
      reliability_boundary: 'unknown_until_durable_telephony_cutover_marker_exists'
    }
  end

  def coverage_state
    return 'not_configured' unless configured?

    'unknown'
  end

  def query_fingerprint
    @query_fingerprint ||= Digest::SHA256.hexdigest(JSON.generate(fingerprint_payload))
  end

  def fingerprint_payload
    {
      kind: QUERY_KIND,
      version: 1,
      account_id: account.id,
      from: from_time.utc.iso8601(6),
      to: to_time.utc.iso8601(6),
      as_of: as_of.iso8601(6),
      dimension: dimension,
      metric: metric,
      long_threshold_seconds: long_threshold_seconds,
      filters: filters.sort.to_h,
      effective_relation_sha256: Digest::SHA256.hexdigest(filtered_occurrences.to_sql),
      effective_inbox_ids_sha256: effective_inbox_ids_digest
    }
  end

  def effective_inbox_ids_digest
    ids = filtered_occurrences.distinct.order(:inbox_id_snapshot).pluck(:inbox_id_snapshot).compact
    Digest::SHA256.hexdigest(ids.join(','))
  end

  def count_or_unknown(observed_count)
    return observed_count if observed_count.positive?

    nil
  end

  def parse_local_time!(zone, key)
    value = params[key]
    raise_validation!("#{key} is required") if value.blank?
    raise_validation!("#{key} must be a local datetime") unless value.is_a?(String)

    match = LOCAL_DATETIME_PATTERN.match(value)
    raise_validation!("#{key} must be an offset-free ISO local datetime") if match.blank?

    local = strict_local_datetime(match)
    zone.tzinfo.local_to_utc(local).to_time.utc.in_time_zone(zone)
  rescue Date::Error, TZInfo::PeriodNotFound, TZInfo::AmbiguousTime
    raise_validation!("#{key} must be an unambiguous existing local datetime")
  end

  def strict_local_datetime(match)
    year, month, day, hour, minute, second = match.captures.first(6).map(&:to_i)
    fraction = match[7].to_s.to_f
    raise Date::Error unless hour.between?(0, 23) && minute.between?(0, 59) && second.between?(0, 59)

    DateTime.new(year, month, day, hour, minute, second + fraction, 0)
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

  def raise_validation!(message)
    raise Telephony::Error.new(code: 'INVALID_REPORT_QUERY', message: message, status: :unprocessable_content)
  end
end
