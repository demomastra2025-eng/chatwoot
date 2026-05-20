class Telephony::AiVoice::ControlService
  ALLOWED_ACTIONS = %w[
    ai_ringing ai_answered ai_speaking caller_interrupted tool_started tool_progress tool_completed tool_failed tool_suppressed
    transfer_started transfer_answered transfer_completed transfer_failed session_completed session_failed
    caller_hangup media_stream_closed media_stream_not_established provider_stream_closed provider_error fonoster_call_closed runtime_closed
    tool_requested_end_call handoff_requested close
    tool_async_completed tool_async_failed post_tool_model_stall
  ].freeze
  BRIDGE_CALL_REF_KEYS = %w[bridge_call_ref bridgeCallRef parent_call_ref parentCallRef].freeze
  RUNTIME_CALL_REF_KEYS = %w[
    runtime_call_ref runtimeCallRef child_call_ref childCallRef ai_runtime_call_ref aiRuntimeCallRef
  ].freeze
  MEDIA_SESSION_REF_KEYS = %w[media_session_ref mediaSessionRef].freeze
  STREAM_REF_KEYS = %w[stream_ref streamRef].freeze

  def initialize(payload:)
    @payload = payload.deep_stringify_keys
  end

  def perform
    ensure_call_session!
    ensure_allowed_action!
    record_control_event!
    sync_conversation_timeline_event!
    ingest_lifecycle_event! if lifecycle_action?

    { status: 'ok', action: action }
  end

  private

  attr_reader :payload

  def record_control_event!
    call_session.with_lock do
      metadata = (call_session.metadata || {}).deep_dup
      ai_voice = metadata['ai_voice'] ||= {}
      ai_voice['control_event_sequence'] = ai_voice['control_event_sequence'].to_i + 1
      @control_event_sequence = ai_voice['control_event_sequence']
      ai_voice['control_events'] ||= []
      ai_voice['control_events'] << {
        'action' => action,
        'metadata' => payload['metadata'].is_a?(Hash) ? payload['metadata'] : {},
        'sequence' => @control_event_sequence,
        'at' => Time.current.iso8601
      }
      ai_voice['control_events'] = ai_voice['control_events'].last(100)
      call_session.update!(metadata: metadata)
    end
  end

  def sync_conversation_timeline_event!
    Telephony::AiVoice::ConversationTimelineService.new(call_session: call_session).record_control_event!(
      action: action,
      metadata: payload['metadata'].is_a?(Hash) ? payload['metadata'] : {},
      sequence: @control_event_sequence
    )
  end

  def ingest_lifecycle_event!
    Telephony::EventsIngestionService.new(payload: lifecycle_event_payload).perform
  end

  def lifecycle_event_payload
    {
      event_key: lifecycle_event_key,
      account_id: call_session.account_id,
      call_ref: call_session.external_call_ref,
      bridge_call_ref: bridge_call_ref,
      runtime_call_ref: runtime_call_ref,
      media_session_ref: metadata_value(*MEDIA_SESSION_REF_KEYS),
      stream_ref: metadata_value(*STREAM_REF_KEYS),
      event: action,
      occurred_at: Time.current.iso8601,
      metadata: lifecycle_metadata
    }.compact
  end

  def lifecycle_event_key
    payload['event_key'].presence || "ai-control:#{call_session.external_call_ref}:#{action}:#{SecureRandom.uuid}"
  end

  def lifecycle_metadata
    @lifecycle_metadata ||= payload['metadata'].is_a?(Hash) ? payload['metadata'].deep_stringify_keys : {}
  end

  def bridge_call_ref
    payload_value(*BRIDGE_CALL_REF_KEYS)
  end

  def runtime_call_ref
    payload_value(*RUNTIME_CALL_REF_KEYS) || metadata_value(*RUNTIME_CALL_REF_KEYS) || linked_payload_call_ref
  end

  def linked_payload_call_ref
    raw_call_ref = payload['call_ref'].presence || payload['callRef'].presence
    return if raw_call_ref.blank? || bridge_call_ref.blank?
    return if raw_call_ref == call_session.external_call_ref

    raw_call_ref
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

  def payload_value(*keys)
    value_for(payload, keys)
  end

  def metadata_value(*keys)
    value_for(lifecycle_metadata, keys)
  end

  def value_for(source, keys)
    keys.each do |key|
      value = source[key]
      return value if value.present?
    end

    nil
  end
end
