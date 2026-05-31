# frozen_string_literal: true

module Llm::Evals::Scenario::StateToolQueries
  def tool_events
    events.select { |event| event[:tool_name].present? || event[:action].to_s.start_with?('tool_') }
  end

  def tool_call?(name)
    tool_call_count(name).positive?
  end
  alias has_tool_call? tool_call?

  def last_tool_call(name)
    tool_events.reverse.find { |event| event[:tool_name].to_s == name.to_s }
  end

  def tool_call_count(name = nil)
    return tool_events.size if name.blank?

    tool_events.count { |event| event[:tool_name].to_s == name.to_s }
  end

  def tool_result_used?(tool:, fragment:, after_user_fragment: nil)
    fragment = fragment.to_s
    return false if fragment.blank?

    completed_tool = completed_tool_with_result_fragment(tool, fragment)
    minimum_index = minimum_tool_result_index(completed_tool, after_user_fragment)
    return false unless minimum_index

    assistant_text.any? { |entry| entry[:index] > minimum_index && text_includes?(entry[:text], fragment) }
  end

  def tool_after_user_fragment?(tool:, fragment:)
    user_turn = user_text.reverse.find { |entry| text_includes?(entry[:text], fragment.to_s) }
    return false unless user_turn

    tool_events.any? { |event| event[:tool_name].to_s == tool.to_s && event[:_index].to_i > user_turn[:index] }
  end

  def mutation_count(resource_type:, id: nil)
    mutating_tool_events.count do |event|
      event[:resource_type].to_s == resource_type.to_s &&
        (id.blank? || event[:resource_id].to_s == id.to_s)
    end
  end

  def duplicate_mutations
    mutating_tool_events
      .group_by { |event| mutation_identity(event) }
      .filter_map { |identity, grouped_events| duplicate_mutation_entry(identity, grouped_events) }
  end

  private

  def completed_tool_with_result_fragment(tool, fragment)
    tool_events.find do |event|
      event[:action].to_s == 'tool_completed' &&
        event[:tool_name].to_s == tool.to_s &&
        text_includes?(event_text(event), fragment)
    end
  end

  def minimum_tool_result_index(completed_tool, after_user_fragment)
    return unless completed_tool

    minimum_index = completed_tool[:_index].to_i
    return minimum_index if after_user_fragment.blank?

    user_turn = user_text.reverse.find { |entry| text_includes?(entry[:text], after_user_fragment.to_s) }
    return unless user_turn

    [minimum_index, user_turn[:index]].max
  end

  def duplicate_mutation_entry(identity, grouped_events)
    return if identity.blank? || grouped_events.size < 2

    {
      identity: identity,
      count: grouped_events.size,
      tool_name: grouped_events.first[:tool_name],
      indexes: grouped_events.pluck(:_index)
    }
  end
end
