# frozen_string_literal: true

class Llm::Evals::CollectionResult
  attr_reader :suites, :generated_at

  def initialize(suites:, generated_at: Time.current)
    @suites = Array(suites)
    @generated_at = generated_at
  end

  def suite_count
    suites.size
  end

  def total_count
    suites.sum(&:total_count)
  end

  def passed_count
    suites.sum(&:passed_count)
  end

  def failed_count
    suites.sum(&:failed_count)
  end

  def error_count
    suites.sum(&:error_count)
  end

  def pass_rate
    return 0.0 if total_count.zero?

    (passed_count.to_f / total_count).round(4)
  end

  def duration_ms
    suite_payloads.sum { |suite| integer_value(suite[:duration_ms]) || case_duration_sum(suite) }
  end

  def estimated_cost
    cost = suite_payloads.sum { |suite| decimal_value(suite[:estimated_cost]) || case_estimated_cost_sum(suite) }
    return if cost.zero?

    cost.round(8)
  end

  def failed_scenarios
    suite_payloads.flat_map do |suite|
      suite_cases(suite).filter_map { |case_result| failed_scenario_summary(suite, case_result) }
    end
  end

  def passed?
    suites.all?(&:passed?)
  end

  def status
    passed? ? 'pass' : 'fail'
  end

  def to_h
    {
      status: status,
      generated_at: generated_at,
      suite_count: suite_count,
      total_count: total_count,
      passed_count: passed_count,
      failed_count: failed_count,
      error_count: error_count,
      pass_rate: pass_rate,
      duration_ms: duration_ms,
      estimated_cost: estimated_cost,
      failed_scenarios: failed_scenarios,
      suites: suite_payloads
    }.compact
  end

  private

  def suite_payloads
    @suite_payloads ||= suites.map { |suite| suite.to_h.deep_symbolize_keys }
  end

  def suite_cases(suite)
    Array(suite[:cases] || suite[:case_summaries]).filter_map do |case_result|
      case_result.to_h.deep_symbolize_keys if case_result.respond_to?(:to_h)
    end
  end

  def case_duration_sum(suite)
    suite_cases(suite).sum { |case_result| integer_value(case_result[:duration_ms]) || 0 }
  end

  def case_estimated_cost_sum(suite)
    suite_cases(suite).sum do |case_result|
      decimal_value(case_result.dig(:artifact, :usage, :estimated_cost)) ||
        decimal_value(case_result.dig(:artifact, :trace_digest, :estimated_cost)) || 0.0
    end
  end

  def failed_scenario_summary(suite, case_result)
    return if case_result[:status].to_s == 'pass'

    {
      suite_id: suite[:suite_id],
      id: case_result[:id],
      description: case_result[:description],
      tags: case_result[:tags],
      status: case_result[:status],
      duration_ms: case_result[:duration_ms],
      failures: case_result[:failures]
    }.compact
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
