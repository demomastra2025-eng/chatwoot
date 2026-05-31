# frozen_string_literal: true

module Llm::Evals::Scenario::StateQueries
  MESSAGE_ROLES = %w[user assistant].freeze

  def messages
    events.select { |event| MESSAGE_ROLES.include?(event[:role].to_s) }
  end

  def new_messages_after(index)
    messages.select { |message| message[:_index].to_i > index.to_i }
  end

  def last_message
    messages.last
  end

  def last_user_message
    messages.reverse.find { |message| message[:role].to_s == 'user' }
  end

  def last_assistant_message
    messages.reverse.find { |message| message[:role].to_s == 'assistant' }
  end

  def turn_count
    messages.size
  end

  def assistant_text
    text_entries_for_role('assistant')
  end

  def user_text
    text_entries_for_role('user')
  end

  def assistant_response_after_last_user?
    last_user = last_user_message
    return false unless last_user

    assistant_text.any? { |entry| entry[:index] > last_user[:_index].to_i && entry[:text].present? }
  end
  alias assistant_answer_after_last_user? assistant_response_after_last_user?

  def ui_action?(type)
    ui_action_types.include?(type.to_s)
  end

  def ui_action_types
    actions = events.flat_map { |event| Array(event[:ui_actions]) + Array(event.dig(:payload, :ui_actions)) }

    actions.filter_map { |action| action.to_h.deep_symbolize_keys[:type].presence }.map(&:to_s).uniq
  end

  def reasoning_present?
    events.any? do |event|
      event[:reasoning].present? || event[:thinking].present? || Array(event[:reasoning_details]).present? ||
        event.dig(:metadata, :reasoning).present?
    end
  end

  def openrouter_generation_ids
    events.flat_map { |event| collect_generation_ids(event) }.map(&:to_s).reject(&:blank?).uniq
  end

  def event_names
    events.filter_map do |event|
      event[:name].presence || event[:event_name].presence || event[:event_type].presence || event[:action].presence
    end.map(&:to_s)
  end

  def summary
    {
      thread_id: thread_id,
      turn_count: turn_count,
      messages: messages,
      tool_events: tool_events,
      ui_action_types: ui_action_types,
      reasoning_present: reasoning_present?,
      openrouter_generation_ids: openrouter_generation_ids,
      event_names: event_names,
      duplicate_mutations: duplicate_mutations,
      terminal_status: terminal_status,
      terminal_reason: terminal_reason
    }.compact
  end

  def event_text(event)
    Llm::Evals::Scenario::StateTextHelpers::TEXT_KEYS
      .filter_map { |key| event[key] }
      .map { |value| value.is_a?(String) ? value : value.to_json }
      .join(' ')
  end
end
