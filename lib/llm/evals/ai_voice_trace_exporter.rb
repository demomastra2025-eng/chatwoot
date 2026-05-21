# frozen_string_literal: true

class Llm::Evals::AiVoiceTraceExporter
  SECRET_KEY_PATTERN = /(api[_-]?key|token|secret|password|authorization|credential)/i
  EVENT_ACTIONS = %w[
    caller_transcript_final
    ai_transcript_turn
    realtime_audio_out
    tool_started
    tool_completed
    tool_failed
    tool_async_completed
    tool_async_failed
    pacer_drop
  ].freeze

  def initialize(account:, inbox_id:, display_id:)
    @account = account
    @inbox_id = inbox_id
    @display_id = display_id
  end

  def call
    exported_case = {
      id: case_id,
      description: description,
      tags: %w[ai_voice imported_conversation regression],
      events: exported_events,
      expected: expected_contract
    }

    { case: exported_case, yaml: YAML.dump('cases' => [deep_stringify_keys(exported_case)]) }
  end

  private

  attr_reader :account, :inbox_id, :display_id

  def conversation
    @conversation ||= account.conversations.find_by!(inbox_id: inbox_id, display_id: display_id)
  end

  def call_sessions
    @call_sessions ||= conversation.telephony_call_sessions.order(:started_at, :created_at, :id).to_a
  end

  def telephony_events
    @telephony_events ||= Telephony::Event.where(call_session_id: call_sessions.map(&:id)).order(:created_at, :id).to_a
  end

  def exported_events
    events = telephony_events.filter_map { |event| export_telephony_event(event) }
    events.presence || transcript_message_events
  end

  def export_telephony_event(event)
    payload = sanitized(event.payload || {})
    nested_payload = payload['payload'].is_a?(Hash) ? payload['payload'] : payload
    action = nested_payload['action'].presence || event.event_type
    return unless EVENT_ACTIONS.include?(action)

    exported = { action: action }
    if nested_payload['tool_name'].present? || nested_payload['toolName'].present?
      exported[:tool_name] =
        nested_payload['tool_name'] || nested_payload['toolName']
    end
    exported[:role] = nested_payload['role'] if nested_payload['role'].present?
    exported[:content] = first_present(nested_payload['content'], nested_payload['text'], nested_payload['transcript'])
    exported[:result] = nested_payload['result'] if nested_payload.key?('result')
    exported[:arguments] = nested_payload['arguments'] if nested_payload.key?('arguments')
    exported.compact
  end

  def transcript_message_events
    conversation.messages.order(:created_at, :id).filter_map do |message|
      next unless message.ai_voice_transcript_turn?

      {
        action: message.outgoing? ? 'ai_transcript_turn' : 'caller_transcript_final',
        role: message.outgoing? ? 'ai' : 'caller',
        content: sanitized(message.content)
      }
    end
  end

  def expected_contract
    expected = {
      require_actions: required_actions,
      forbid_actions: ['pacer_drop'],
      forbid_failed_tools: tool_names
    }
    usage = tool_result_usage
    expected[:require_tool_result_usage] = usage if usage.present?
    expected
  end

  def required_actions
    actions = exported_events.pluck(:action)
    required = []
    required << 'tool_completed' if actions.include?('tool_completed')
    required << 'ai_transcript_turn' if actions.include?('ai_transcript_turn')
    required << 'realtime_audio_out' if actions.include?('realtime_audio_out')
    required.presence || ['ai_transcript_turn']
  end

  def tool_names
    exported_events.filter_map { |event| event[:tool_name] }.uniq
  end

  def tool_result_usage
    exported_events.filter_map do |event|
      next unless event[:action] == 'tool_completed' && event[:tool_name].present?

      fragment = extract_result_fragment(event[:result])
      next if fragment.blank?

      { tool: event[:tool_name], fragment: fragment }
    end
  end

  def extract_result_fragment(result)
    return result.to_s.truncate(80, omission: '') unless result.is_a?(Hash)

    content = result[:content] || result['content'] || result[:message] || result['message']
    case content
    when Hash
      first_present(content[:amount], content['amount'], content[:title], content['title'], content[:id], content['id'])&.to_s
    when Array
      content.first.to_s.truncate(80, omission: '')
    else
      content.to_s.truncate(80, omission: '')
    end
  end

  def case_id
    "conversation_#{conversation.display_id}_ai_voice_trace"
  end

  def description
    [
      "Imported AI Voice regression trace for account #{account.id}",
      "inbox #{conversation.inbox_id}",
      "conversation display #{conversation.display_id}."
    ].join(', ')
  end

  def first_present(*values)
    values.find(&:present?)
  end

  def sanitized(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, nested_value), sanitized_hash|
        sanitized_hash[key] = key.to_s.match?(SECRET_KEY_PATTERN) ? '[REDACTED]' : sanitized(nested_value)
      end
    when Array
      value.map { |nested_value| sanitized(nested_value) }
    else
      value
    end
  end

  def deep_stringify_keys(value)
    case value
    when Hash
      value.transform_keys(&:to_s).transform_values { |nested_value| deep_stringify_keys(nested_value) }
    when Array
      value.map { |nested_value| deep_stringify_keys(nested_value) }
    else
      value
    end
  end
end
