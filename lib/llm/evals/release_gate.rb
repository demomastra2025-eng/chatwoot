# frozen_string_literal: true

class Llm::Evals::ReleaseGate
  DEFAULT_MAX_FAILED_COUNT = 0
  DEFAULT_MAX_ERROR_COUNT = 0
  DEFAULT_MIN_PASS_RATE = 1.0
  DEFAULT_MAX_SCHEMA_INVALID_COUNT = 0
  DEFAULT_MAX_TOOL_FAILURE_COUNT = 0
  DEFAULT_MAX_NO_CONTENT_COUNT = 0
  DEFAULT_MAX_ZERO_COMPLETION_COUNT = 0
  DEFAULT_MAX_CATALOG_STALE_COUNT = 0
  DEFAULT_MAX_CRITICAL_FAILURE_COUNT = 0
  DEFAULT_MAX_DURATION_MS = nil
  DEFAULT_MAX_ESTIMATED_COST = nil
  CATEGORY_MATCHERS = {
    schema_invalid: [/schema/i, /structured[\s_-]?output/i, /response_format/i, /json schema/i],
    tool_failure: [
      /tool[\s_-]?(failure|failures|failed|error|errors|timeout|timeouts|exception|exceptions)/i,
      /(failure|failures|failed|error|errors|timeout|timeouts|exception|exceptions).*tool/i
    ],
    no_content: [/no[\s_-]?content/i, /blank response/i, /empty response/i],
    zero_completion: [/zero[\s_-]?completion/i, /no[\s_-]?final[\s_-]?answer/i, /finalization[\s_-]?only/i],
    catalog_stale: [/catalog/i, /stale/i],
    critical_failure: [/critical[\s_-]?failure/i, /\bcritical\b/i]
  }.freeze
  CATEGORY_GATES = [
    [:schema_invalid_count, :max_schema_invalid_count, 'schema invalid eval cases'],
    [:tool_failure_count, :max_tool_failure_count, 'tool failure eval cases'],
    [:no_content_count, :max_no_content_count, 'no-content eval cases'],
    [:zero_completion_count, :max_zero_completion_count, 'zero-completion eval cases'],
    [:catalog_stale_count, :max_catalog_stale_count, 'catalog stale eval cases'],
    [:critical_failure_count, :max_critical_failure_count, 'critical eval failures']
  ].freeze

  def initialize(**attributes)
    @result = attributes.fetch(:result)
    @required_pack_ids = normalize_ids(attributes[:required_pack_ids] || default_required_pack_ids)
    @max_failed_count = normalized_limit(attributes, :max_failed_count, DEFAULT_MAX_FAILED_COUNT)
    @max_error_count = normalized_limit(attributes, :max_error_count, DEFAULT_MAX_ERROR_COUNT)
    @min_pass_rate = normalize_pass_rate(attributes.fetch(:min_pass_rate, DEFAULT_MIN_PASS_RATE))
    @max_schema_invalid_count = normalized_limit(attributes, :max_schema_invalid_count, DEFAULT_MAX_SCHEMA_INVALID_COUNT)
    @max_tool_failure_count = normalized_limit(attributes, :max_tool_failure_count, DEFAULT_MAX_TOOL_FAILURE_COUNT)
    @max_no_content_count = normalized_limit(attributes, :max_no_content_count, DEFAULT_MAX_NO_CONTENT_COUNT)
    @max_zero_completion_count = normalized_limit(attributes, :max_zero_completion_count, DEFAULT_MAX_ZERO_COMPLETION_COUNT)
    @max_catalog_stale_count = normalized_limit(attributes, :max_catalog_stale_count, DEFAULT_MAX_CATALOG_STALE_COUNT)
    @max_critical_failure_count = normalized_limit(attributes, :max_critical_failure_count, DEFAULT_MAX_CRITICAL_FAILURE_COUNT)
    @max_duration_ms = normalized_optional_integer(attributes.fetch(:max_duration_ms, DEFAULT_MAX_DURATION_MS), 'max_duration_ms')
    @max_estimated_cost = normalized_optional_float(attributes.fetch(:max_estimated_cost, DEFAULT_MAX_ESTIMATED_COST), 'max_estimated_cost')
  end

  def call
    failures = gate_failures

    {
      status: failures.empty? ? 'pass' : 'fail',
      passed: failures.empty?,
      failures: failures,
      summary: summary,
      required_pack_ids: required_pack_ids
    }
  end

  private

  attr_reader :result, :required_pack_ids, :max_failed_count, :max_error_count, :min_pass_rate,
              :max_schema_invalid_count, :max_tool_failure_count, :max_no_content_count, :max_catalog_stale_count,
              :max_zero_completion_count, :max_critical_failure_count, :max_duration_ms, :max_estimated_cost

  def gate_failures
    failures = []
    failures.concat(count_failures)
    failures.concat(category_failures)
    failures.concat(cost_duration_failures)
    failures.concat(required_pack_failures)
    failures
  end

  def count_failures
    [].tap do |failures|
      failures << "eval failures exceeded gate: #{summary[:failed_count]} > #{max_failed_count}" if summary[:failed_count].to_i > max_failed_count
      failures << "eval errors exceeded gate: #{summary[:error_count]} > #{max_error_count}" if summary[:error_count].to_i > max_error_count
      failures << "eval pass rate below gate: #{summary[:pass_rate]} < #{min_pass_rate}" if summary[:pass_rate].to_f < min_pass_rate
    end
  end

  def category_failures
    CATEGORY_GATES.filter_map do |summary_key, limit_reader, label|
      actual_count = summary[summary_key].to_i
      limit = send(limit_reader)

      "#{label} exceeded gate: #{actual_count} > #{limit}" if actual_count > limit
    end
  end

  def cost_duration_failures
    [].tap do |failures|
      if max_duration_ms.present? && summary[:duration_ms].to_i > max_duration_ms
        failures << "eval duration exceeded gate: #{summary[:duration_ms]} > #{max_duration_ms}"
      end
      if max_estimated_cost.present? && summary[:estimated_cost].to_f > max_estimated_cost
        failures << "eval estimated cost exceeded gate: #{summary[:estimated_cost]} > #{max_estimated_cost}"
      end
    end
  end

  def required_pack_failures
    missing_pack_ids = required_pack_ids - suite_ids
    return [] if missing_pack_ids.empty?

    ["required eval packs missing: #{missing_pack_ids.join(', ')}"]
  end

  def summary
    @summary ||= {
      suite_count: suites.size,
      total_count: aggregate_count(:total_count),
      passed_count: aggregate_count(:passed_count),
      failed_count: aggregate_count(:failed_count),
      error_count: aggregate_count(:error_count),
      pass_rate: aggregate_pass_rate,
      schema_invalid_count: category_count(:schema_invalid),
      tool_failure_count: category_count(:tool_failure),
      no_content_count: category_count(:no_content),
      zero_completion_count: category_count(:zero_completion),
      catalog_stale_count: category_count(:catalog_stale),
      critical_failure_count: category_count(:critical_failure),
      duration_ms: aggregate_duration_ms,
      estimated_cost: aggregate_estimated_cost
    }
  end

  def aggregate_count(key)
    suites.sum { |suite| suite[key].to_i }
  end

  def aggregate_pass_rate
    return 0.0 if summary_total_count.zero?

    (summary_passed_count.to_f / summary_total_count).round(4)
  end

  def category_count(category)
    matchers = CATEGORY_MATCHERS.fetch(category)
    failing_cases.count { |case_result| category_match?(case_result, matchers) }
  end

  def failing_cases
    @failing_cases ||= suites.flat_map do |suite|
      Array(suite[:cases]).filter_map do |case_result|
        normalized = case_result.respond_to?(:to_h) ? case_result.to_h.deep_symbolize_keys : nil
        normalized if normalized.present? && normalized[:status].to_s != 'pass'
      end
    end
  end

  def category_match?(case_result, matchers)
    text = category_match_text(case_result)
    matchers.any? { |matcher| text.match?(matcher) }
  end

  def category_match_text(case_result)
    [
      case_result[:id],
      case_result[:description],
      case_result[:tags],
      case_result[:failures],
      case_result[:expected],
      case_result[:actual]
    ].flatten.compact.map(&:to_s).join(' ')
  end

  def aggregate_duration_ms
    direct_duration = integer_value(result_payload[:duration_ms])
    return direct_duration if direct_duration

    suites.sum do |suite|
      integer_value(suite[:duration_ms]) ||
        Array(suite[:cases]).sum { |case_result| integer_value(case_result.to_h[:duration_ms]) || 0 }
    end
  end

  def aggregate_estimated_cost
    direct_cost = decimal_value(result_payload[:estimated_cost])
    return direct_cost if direct_cost

    cost = suites.sum do |suite|
      decimal_value(suite[:estimated_cost]) ||
        Array(suite[:cases]).sum { |case_result| decimal_value(case_result.to_h.dig(:artifact, :usage, :estimated_cost)) || 0.0 }
    end
    cost.round(8)
  end

  def summary_total_count
    aggregate_count(:total_count)
  end

  def summary_passed_count
    aggregate_count(:passed_count)
  end

  def suite_ids
    @suite_ids ||= normalize_ids(suites.filter_map { |suite| suite[:suite_id] || suite[:id] })
  end

  def suites
    @suites ||= begin
      payload = result_payload
      raw_suites = payload.key?(:suites) ? payload[:suites] : [payload]
      Array(raw_suites).map { |suite| suite.to_h.deep_symbolize_keys }
    end
  end

  def result_payload
    payload = result.respond_to?(:to_h) ? result.to_h : result
    payload.to_h.deep_symbolize_keys
  end

  def default_required_pack_ids
    Llm::Evals::PackRegistry.default_packs(include_live: false).map(&:id)
  end

  def normalize_ids(ids)
    Array(ids).filter_map { |id| id.to_s.presence }.uniq
  end

  def normalized_limit(attributes, key, fallback)
    normalize_non_negative_integer(attributes.fetch(key, fallback), key.to_s)
  end

  def normalize_non_negative_integer(value, name)
    return value if value.is_a?(Integer) && value >= 0

    string_value = value.to_s
    return string_value.to_i if string_value.match?(/\A\d+\z/)

    raise ArgumentError, "#{name} must be a non-negative integer"
  end

  def normalized_optional_integer(value, name)
    return if value.blank?

    normalize_non_negative_integer(value, name)
  end

  def normalized_optional_float(value, name)
    return if value.blank?

    Float(value)
  rescue ArgumentError, TypeError
    raise ArgumentError, "#{name} must be a number"
  end

  def normalize_pass_rate(value)
    numeric_value = Float(value)
    return numeric_value if numeric_value.between?(0.0, 1.0)

    raise ArgumentError
  rescue ArgumentError, TypeError
    raise ArgumentError, 'min_pass_rate must be a number between 0.0 and 1.0'
  end

  def integer_value(value)
    Integer(value) if value.present?
  rescue ArgumentError, TypeError
    nil
  end

  def decimal_value(value)
    Float(value) if value.present?
  rescue ArgumentError, TypeError
    nil
  end
end
