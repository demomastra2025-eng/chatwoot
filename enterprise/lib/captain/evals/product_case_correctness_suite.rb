# frozen_string_literal: true

class Captain::Evals::ProductCaseCorrectnessSuite
  SUITE_ID = 'captain.product_case_correctness'
  DEFAULT_CASES_PATH = Rails.root.join('config/llm_evals/product_case_correctness.yml')

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
    actual = analyze(eval_case.dig(:input, :events))
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

  def analyze(raw_events)
    events = Array(raw_events).map.with_index do |event, index|
      event.to_h.deep_symbolize_keys.merge(_index: index)
    end

    {
      user_text: role_text(events, %w[user customer caller], action_fragments: %w[user customer caller]),
      assistant_text: role_text(events, %w[assistant ai], action_fragments: %w[assistant ai response]),
      tool_events: tool_events(events),
      ui_action_types: ui_action_types(events)
    }
  end

  def role_text(events, roles, action_fragments: [])
    events.filter_map do |event|
      role = (event[:role] || event.dig(:payload, :role)).to_s
      action = event_action(event).to_s
      text = event_text(event)
      next if text.blank?
      next unless roles.include?(role) || action_fragments.any? { |fragment| action.include?(fragment) }

      { index: event[:_index], text: text }
    end
  end

  def tool_events(events)
    events.filter_map do |event|
      action = event_action(event).to_s
      tool = tool_name(event)
      next if tool.blank? && !action.start_with?('tool_')

      {
        index: event[:_index],
        action: action,
        tool_name: tool,
        text: event_text(event)
      }
    end
  end

  def ui_action_types(events)
    events.flat_map do |event|
      Array(event[:ui_actions]) + Array(event.dig(:payload, :ui_actions))
    end.filter_map do |action|
      action.to_h.deep_symbolize_keys[:type].presence
    end.map(&:to_s).uniq
  end

  def compare(actual, expected)
    expected = expected.to_h.deep_symbolize_keys
    failures = []

    compare_assistant_response(actual, expected, failures)
    compare_answer_fragments(actual, expected, failures)
    compare_tools(actual, expected, failures)
    compare_tool_result_usage(actual, expected, failures)
    compare_tool_after_user_fragment(actual, expected, failures)
    compare_ui_actions(actual, expected, failures)

    failures
  end

  def compare_assistant_response(actual, expected, failures)
    return unless expected[:require_assistant_response_after_last_user]

    last_user = actual[:user_text].last
    has_response = last_user && actual[:assistant_text].any? { |event| event[:index] > last_user[:index] }
    failures << 'assistant response missing after last user message' unless has_response
  end

  def compare_answer_fragments(actual, expected, failures)
    assistant_text = actual[:assistant_text].pluck(:text).join(' ')

    Array(expected[:require_answer_fragments]).each do |fragment|
      next if assistant_text.include?(fragment.to_s)

      failures << "assistant answer missing fragment: #{fragment}"
    end

    Array(expected[:forbid_answer_fragments]).each do |fragment|
      next unless assistant_text.include?(fragment.to_s)

      failures << "assistant answer contains forbidden fragment: #{fragment}"
    end
  end

  def compare_tools(actual, expected, failures)
    used_tools = actual[:tool_events].pluck(:tool_name).reject(&:blank?)
    tool_usage_count = actual[:tool_events].size

    Array(expected[:require_tools]).each do |tool|
      failures << "required tool missing: #{tool}" unless used_tools.include?(tool.to_s)
    end

    Array(expected[:forbid_tools]).each do |tool|
      if tool.to_s == '*'
        failures << "unexpected tools present: #{tool_usage_labels(actual[:tool_events]).join(', ')}" if tool_usage_count.positive?
      elsif used_tools.include?(tool.to_s)
        failures << "forbidden tool present: #{tool}"
      end
    end

    max_tool_count = expected[:max_tool_count]
    return if max_tool_count.blank? || tool_usage_count <= max_tool_count.to_i

    failures << "tool count too high: #{tool_usage_count} > #{max_tool_count}"
  end

  def tool_usage_labels(tool_events)
    tool_events.map { |event| event[:tool_name].presence || event[:action].presence || 'unknown_tool' }
  end

  def compare_tool_result_usage(actual, expected, failures)
    Array(expected[:require_tool_result_usage]).each do |requirement|
      requirement = requirement.to_h.deep_symbolize_keys
      next if tool_result_used?(actual, requirement)

      failures << "tool result fragment was not used after #{requirement[:tool]}: #{requirement[:fragment]}"
    end
  end

  def tool_result_used?(actual, requirement)
    fragment = requirement[:fragment].to_s
    return false if fragment.blank?

    completed_tool = actual[:tool_events].find do |event|
      event[:action] == 'tool_completed' && event[:tool_name] == requirement[:tool].to_s && event[:text].include?(fragment)
    end
    return false unless completed_tool

    minimum_index = completed_tool[:index]
    after_user_fragment = requirement[:after_user_fragment].to_s
    if after_user_fragment.present?
      user_turn = actual[:user_text].reverse.find { |event| event[:text].include?(after_user_fragment) }
      return false unless user_turn

      minimum_index = [minimum_index, user_turn[:index]].max
    end

    actual[:assistant_text].any? { |event| event[:index] > minimum_index && event[:text].include?(fragment) }
  end

  def compare_tool_after_user_fragment(actual, expected, failures)
    Array(expected[:require_tool_after_user_fragment]).each do |requirement|
      requirement = requirement.to_h.deep_symbolize_keys
      next if tool_after_user_fragment?(actual, requirement)

      failures << "tool #{requirement[:tool]} executed before required user fragment: #{requirement[:fragment]}"
    end
  end

  def tool_after_user_fragment?(actual, requirement)
    fragment = requirement[:fragment].to_s
    tool = requirement[:tool].to_s
    user_turn = actual[:user_text].reverse.find { |event| event[:text].include?(fragment) }
    return false unless user_turn

    actual[:tool_events].any? { |event| event[:tool_name] == tool && event[:index] > user_turn[:index] }
  end

  def compare_ui_actions(actual, expected, failures)
    Array(expected[:require_ui_actions]).each do |action_type|
      next if actual[:ui_action_types].include?(action_type.to_s)

      failures << "required ui_action missing: #{action_type}"
    end
  end

  def event_action(event)
    event[:action] || event[:event_type] || event.dig(:payload, :action) || event.dig(:payload, :payload, :action)
  end

  def tool_name(event)
    (event[:tool_name] || event[:name] || event.dig(:payload, :tool_name) || event.dig(:payload, :name) ||
      event.dig(:payload, :payload, :tool_name)).to_s
  end

  def event_text(event)
    values = [
      event[:content],
      event[:text],
      event[:transcript],
      event[:result],
      event.dig(:payload, :content),
      event.dig(:payload, :text),
      event.dig(:payload, :transcript),
      event.dig(:payload, :result),
      event.dig(:payload, :payload, :content),
      event.dig(:payload, :payload, :result)
    ]

    values.compact.map { |value| value.is_a?(String) ? value : value.to_json }.join(' ')
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end
end
