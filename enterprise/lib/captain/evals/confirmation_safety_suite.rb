# frozen_string_literal: true

class Captain::Evals::ConfirmationSafetySuite
  SUITE_ID = 'captain.confirmation_safety'
  DEFAULT_CASES_PATH = Rails.root.join('config/llm_evals/confirmation_safety.yml')

  def initialize(cases_path: DEFAULT_CASES_PATH)
    @cases_path = Pathname.new(cases_path)
  end

  def call
    ::Llm::Evals::Result.new(
      suite_id: SUITE_ID,
      prompt_id: nil,
      prompt_sha: nil,
      model: nil,
      cases: eval_cases.map { |eval_case| evaluate_case(eval_case) }
    )
  end

  private

  def eval_cases
    @eval_cases ||= ::Llm::Evals::CaseLoader.new(path: @cases_path).load
  end

  def evaluate_case(eval_case)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    actual = analyze(eval_case[:input])
    failures = compare(actual, eval_case.fetch(:expected, {}))

    case_result(eval_case, actual, failures, elapsed_ms(started_at))
  rescue StandardError => e
    case_result(eval_case, { error: "#{e.class.name}: #{e.message}" }, ['runtime_error'], elapsed_ms(started_at), status: 'error')
  end

  def case_result(eval_case, actual, failures, duration_ms, status: nil)
    {
      id: eval_case[:id],
      description: eval_case[:description],
      tags: eval_case[:tags],
      status: status || (failures.empty? ? 'pass' : 'fail'),
      expected: eval_case[:expected],
      actual: actual,
      failures: failures,
      duration_ms: duration_ms
    }.compact
  end

  def analyze(input)
    input = input.to_h.deep_symbolize_keys
    scope = input[:scope].presence || Captain::ToolAccess::SCOPE_ASSISTANT
    include_missing_idempotency = boolean(input[:include_missing_idempotency])
    definitions, missing_tool_ids = selected_definitions(input, scope)
    checked_tools = definitions.map { |definition| checked_tool(definition, scope, include_missing_idempotency) }

    confirmation_summary(scope, include_missing_idempotency, checked_tools, missing_tool_ids)
  end

  def checked_tool(definition, scope, include_missing_idempotency)
    tool = definition.to_h.deep_symbolize_keys
    {
      id: tool[:id].to_s,
      risk_level: tool[:risk_level].to_s.presence || 'medium',
      requires_confirmation: Captain::ToolCatalog.requires_confirmation_for_scope?(
        tool,
        scope,
        include_missing_idempotency: include_missing_idempotency
      )
    }
  end

  def confirmation_summary(scope, include_missing_idempotency, checked_tools, missing_tool_ids)
    {
      scope: scope.to_s,
      include_missing_idempotency: include_missing_idempotency,
      checked_count: checked_tools.size,
      checked_tool_ids: checked_tools.pluck(:id),
      missing_tool_ids: missing_tool_ids,
      tools: checked_tools
    }
  end

  def selected_definitions(input, scope)
    definitions = definitions_for(input, scope)
    by_id = definitions.index_by { |definition| definition[:id].to_s }
    requested_ids = Array(input[:tool_ids]).map(&:to_s)

    return [requested_ids.filter_map { |id| by_id[id] }, requested_ids.reject { |id| by_id.key?(id) }] if requested_ids.present?

    [filter_definitions(definitions, input), []]
  end

  def definitions_for(input, scope)
    raw_definitions = if input[:source].to_s == 'registry'
                        Captain::ToolRegistry.tools_for_scope(scope)
                      else
                        Array(input[:definitions])
                      end

    raw_definitions.map { |definition| definition.to_h.deep_symbolize_keys }
  end

  def filter_definitions(definitions, input)
    excluded_ids = Array(input[:exclude_tool_ids]).map(&:to_s)
    definitions = definitions.reject { |definition| excluded_ids.include?(definition[:id].to_s) }

    risk_levels = Array(input[:risk_levels]).map(&:to_s)
    return definitions if risk_levels.blank?

    definitions.select do |definition|
      risk_levels.include?((definition[:risk_level].presence || 'medium').to_s)
    end
  end

  def compare(actual, expected)
    expected = expected.to_h.deep_symbolize_keys
    failures = []

    compare_missing_tools(actual, failures)
    compare_min_tool_count(actual, expected, failures)
    compare_confirmation(actual, expected, failures)

    failures
  end

  def compare_missing_tools(actual, failures)
    return if actual[:missing_tool_ids].blank?

    failures << "missing registry tools: #{actual[:missing_tool_ids].join(', ')}"
  end

  def compare_min_tool_count(actual, expected, failures)
    min_tool_count = expected[:min_tool_count].to_i
    return unless min_tool_count.positive?
    return if actual[:checked_count].to_i >= min_tool_count

    failures << "checked tool count too low: #{actual[:checked_count]} < #{min_tool_count}"
  end

  def compare_confirmation(actual, expected, failures)
    return unless expected.key?(:requires_confirmation)

    expected_value = boolean(expected[:requires_confirmation])
    actual[:tools].each do |tool|
      next if tool[:requires_confirmation] == expected_value

      failures << "confirmation mismatch for #{tool[:id]}: expected #{expected_value}, got #{tool[:requires_confirmation]}"
    end
  end

  def boolean(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end
end
