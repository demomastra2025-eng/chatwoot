module Captain::Assistant::TracePayloadHelper
  private

  def enrich_context_with_trace_payload!(context, message_history, message_to_process)
    preferences = context.dig(:state, :captain_runtime)
    context[:captain_v2_trace_input] = serialize_trace_messages(message_history, preferences: preferences)
    context[:captain_v2_trace_current_input] = serialize_trace_content(message_to_process, preferences: preferences)
  end

  def serialize_trace_messages(message_history, preferences:)
    payload = message_history.map do |message|
      {
        role: message[:role].to_s,
        content: trace_content_payload(message[:content])
      }
    end

    Llm::TracePayloadPolicy.capture(payload, direction: :input, preferences: preferences)
  end

  def serialize_trace_content(content, preferences:)
    payload = trace_content_payload(content)
    return nil if payload.blank?

    Llm::TracePayloadPolicy.capture(payload, direction: :input, preferences: preferences)
  end

  def trace_content_payload(content)
    payload = Llm::MessageFormat.serialize_content(content)
    return '' if payload.blank?

    payload
  end
end
