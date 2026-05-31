# frozen_string_literal: true

class Llm::Evals::Scenario::ExpectationEvaluator
  def initialize(state:, expected:)
    @state = state
    @expected = expected.to_h.deep_symbolize_keys
  end

  def call
    failures = []

    compare_assistant_response(failures)
    compare_answer_fragments(failures)
    compare_tools(failures)
    compare_tool_result_usage(failures)
    compare_tool_after_user_fragment(failures)
    compare_ui_actions(failures)
    compare_mutations(failures)
    compare_reasoning(failures)
    compare_events(failures)
    compare_openrouter_metadata(failures)

    failures
  end

  private

  attr_reader :state, :expected

  def compare_assistant_response(failures)
    return unless expected[:require_assistant_response_after_last_user]
    return if state.assistant_response_after_last_user?

    failures << 'assistant response missing after last user message'
  end

  def compare_answer_fragments(failures)
    assistant_text = state.assistant_text.pluck(:text).join(' ')

    Array(expected[:require_answer_fragments]).each do |fragment|
      failures << "assistant answer missing fragment: #{fragment}" unless assistant_text.include?(fragment.to_s)
    end

    Array(expected[:forbid_answer_fragments]).each do |fragment|
      failures << "assistant answer contains forbidden fragment: #{fragment}" if assistant_text.include?(fragment.to_s)
    end
  end

  def compare_tools(failures)
    used_tools = state.tool_events.pluck(:tool_name).reject(&:blank?)
    tool_usage_count = state.tool_events.size

    compare_required_tools(failures, used_tools)
    compare_forbidden_tools(failures, used_tools, tool_usage_count)
    compare_max_tool_count(failures, tool_usage_count)
  end

  def compare_required_tools(failures, used_tools)
    Array(expected[:require_tools]).each do |tool|
      failures << "required tool missing: #{tool}" unless used_tools.include?(tool.to_s)
    end
  end

  def compare_forbidden_tools(failures, used_tools, tool_usage_count)
    Array(expected[:forbid_tools]).each do |tool|
      compare_forbidden_tool(failures, used_tools, tool_usage_count, tool)
    end
  end

  def compare_forbidden_tool(failures, used_tools, tool_usage_count, tool)
    if tool.to_s == '*'
      failures << "unexpected tools present: #{tool_usage_labels.join(', ')}" if tool_usage_count.positive?
    elsif used_tools.include?(tool.to_s)
      failures << "forbidden tool present: #{tool}"
    end
  end

  def compare_max_tool_count(failures, tool_usage_count)
    max_tool_count = expected[:max_tool_count]
    return if max_tool_count.blank? || tool_usage_count <= max_tool_count.to_i

    failures << "tool count too high: #{tool_usage_count} > #{max_tool_count}"
  end

  def compare_tool_result_usage(failures)
    Array(expected[:require_tool_result_usage]).each do |raw_requirement|
      requirement = raw_requirement.to_h.deep_symbolize_keys
      next if state.tool_result_used?(
        tool: requirement[:tool],
        fragment: requirement[:fragment],
        after_user_fragment: requirement[:after_user_fragment]
      )

      failures << "tool result fragment was not used after #{requirement[:tool]}: #{requirement[:fragment]}"
    end
  end

  def compare_tool_after_user_fragment(failures)
    Array(expected[:require_tool_after_user_fragment]).each do |raw_requirement|
      requirement = raw_requirement.to_h.deep_symbolize_keys
      next if state.tool_after_user_fragment?(tool: requirement[:tool], fragment: requirement[:fragment])

      failures << "tool #{requirement[:tool]} executed before required user fragment: #{requirement[:fragment]}"
    end
  end

  def compare_ui_actions(failures)
    Array(expected[:require_ui_actions]).each do |action_type|
      failures << "required ui_action missing: #{action_type}" unless state.ui_action?(action_type)
    end
  end

  def compare_mutations(failures)
    return unless expected[:forbid_duplicate_mutations]
    return if state.duplicate_mutations.empty?

    failures << "duplicate mutations present: #{state.duplicate_mutations.pluck(:identity).join(', ')}"
  end

  def compare_reasoning(failures)
    return unless expected[:require_reasoning_present]
    return if state.reasoning_present?

    failures << 'reasoning missing'
  end

  def compare_events(failures)
    Array(expected[:require_event_names]).each do |event_name|
      failures << "required event missing: #{event_name}" unless state.event_names.include?(event_name.to_s)
    end
  end

  def compare_openrouter_metadata(failures)
    return unless expected[:require_openrouter_generation_id]
    return if state.openrouter_generation_ids.present?

    failures << 'openrouter generation id missing'
  end

  def tool_usage_labels
    state.tool_events.map { |event| event[:tool_name].presence || event[:action].presence || 'unknown_tool' }
  end
end
