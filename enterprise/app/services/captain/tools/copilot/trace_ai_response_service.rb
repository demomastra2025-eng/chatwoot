# frozen_string_literal: true

class Captain::Tools::Copilot::TraceAiResponseService < Captain::Tools::Copilot::BaseObservabilityService
  def self.name
    'trace_ai_response'
  end

  description 'Trace an account-scoped Captain/LLM response by trace, request, session, or conversation identifier'
  param :trace_id, type: :string, desc: 'Trace identifier.', required: false
  param :request_id, type: :string, desc: 'Request identifier.', required: false
  param :session_id, type: :string, desc: 'Session identifier.', required: false
  param :conversation_id, type: :number, desc: 'Internal conversation ID.', required: false
  param :conversation_display_id, type: :number, desc: 'Conversation display ID.', required: false
  param :since, type: :string, desc: 'Start time as ISO8601 or Unix timestamp. Defaults to 24 hours ago.', required: false
  param :until, type: :string, desc: 'End time as ISO8601 or Unix timestamp. Defaults to now.', required: false
  param :limit, type: :number, desc: 'Maximum number of trace events to return. Capped at 100.', required: false

  def execute(trace_id: nil, request_id: nil, session_id: nil, conversation_id: nil, conversation_display_id: nil, since: nil, limit: nil, **kwargs)
    return 'trace_id, request_id, session_id, conversation_id, or conversation_display_id is required' unless trace_filter_present?(trace_id,
                                                                                                                                    request_id, session_id, conversation_id, conversation_display_id)

    range = time_range(since, kwargs[:until])
    scoped = event_scope(range)
             .for_trace_id(trace_id)
             .for_request_id(request_id)
             .for_session_id(session_id)
             .for_conversation(conversation_id)
             .for_conversation_display_id(conversation_display_id)
    total_count = scoped.count
    events = scoped.order(:created_at, :id).limit(observability_limit(limit)).map { |event| serialize_llm_event(event) }

    formatted_payload(
      account_id: account.id,
      matched_count: total_count,
      filters: {
        trace_id: trace_id,
        request_id: request_id,
        session_id: session_id,
        conversation_id: conversation_id,
        conversation_display_id: conversation_display_id
      }.compact,
      range: { since: range.begin.iso8601, until: range.end.iso8601 },
      events: events
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def trace_filter_present?(*values)
    values.any?(&:present?)
  end
end
