class Telephony::AiVoice::ControlService
  ALLOWED_ACTIONS = %w[
    ai_ringing ai_answered ai_speaking caller_interrupted tool_started tool_completed tool_failed
    transfer_started transfer_answered transfer_completed transfer_failed session_completed session_failed
    caller_hangup media_stream_closed media_stream_not_established provider_stream_closed provider_error fonoster_call_closed runtime_closed
    tool_requested_end_call handoff_requested close
  ].freeze

  def initialize(payload:)
    @payload = payload.deep_stringify_keys
  end

  def perform
    ensure_call_session!
    ensure_allowed_action!
    record_control_event!
    ingest_lifecycle_event! if lifecycle_action?

    { status: 'ok', action: action }
  end

  private

  attr_reader :payload

  def record_control_event!
    metadata = (call_session.metadata || {}).deep_dup
    ai_voice = metadata['ai_voice'] ||= {}
    ai_voice['control_events'] ||= []
    ai_voice['control_events'] << {
      'action' => action,
      'metadata' => payload['metadata'].is_a?(Hash) ? payload['metadata'] : {},
      'at' => Time.current.iso8601
    }
    ai_voice['control_events'] = ai_voice['control_events'].last(100)
    call_session.update!(metadata: metadata)
  end

  def ingest_lifecycle_event!
    Telephony::EventsIngestionService.new(
      payload: {
        event_key: payload['event_key'].presence || "ai-control:#{call_session.external_call_ref}:#{action}:#{SecureRandom.uuid}",
        account_id: call_session.account_id,
        call_ref: call_session.external_call_ref,
        event: action,
        occurred_at: Time.current.iso8601,
        metadata: payload['metadata'].is_a?(Hash) ? payload['metadata'] : {}
      }
    ).perform
  end

  def lifecycle_action?
    action != 'handoff_requested'
  end

  def ensure_call_session!
    return if call_session.present?

    raise Telephony::Error.new(code: 'CALL_SESSION_NOT_FOUND', message: 'Unable to resolve call session for control action', status: :not_found)
  end

  def ensure_allowed_action!
    return if ALLOWED_ACTIONS.include?(action)

    raise Telephony::Error.new(code: 'CONTROL_ACTION_NOT_ALLOWED', message: 'Control action is not allowed', status: :unprocessable_content)
  end

  def action
    @action ||= payload['action'].to_s
  end

  def call_session
    @call_session ||= Telephony::AiVoice::CallSessionResolver.new(payload: payload).call_session
  end
end
