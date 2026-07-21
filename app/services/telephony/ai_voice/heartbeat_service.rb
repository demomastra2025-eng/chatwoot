class Telephony::AiVoice::HeartbeatService
  def initialize(payload:)
    @payload = payload.deep_stringify_keys
  end

  def perform
    validate_payload!
    session = call_session
    raise_call_session_not_found! if session.blank?

    now = Time.current
    terminal = false
    session.with_lock do
      terminal = session.terminal?
      touch_runtime_lease!(session, now) unless terminal
    end

    {
      status: 'ok',
      terminal: terminal,
      call_session_id: session.id,
      call_status: session.status,
      server_time: now.iso8601(3)
    }
  end

  private

  attr_reader :payload

  def call_session
    resolver_payload = payload.merge('call_id' => payload['call_session_id'].presence || payload['callSessionId'].presence || payload['call_id'])
    Telephony::AiVoice::CallSessionResolver.new(payload: resolver_payload).call_session
  end

  def touch_runtime_lease!(session, now)
    metadata = session.metadata.to_h.deep_stringify_keys
    validate_runtime_lease_identity!(metadata['runtime_lease'])
    metadata['runtime_lease'] = runtime_lease_metadata(now)

    attributes = { metadata: metadata, updated_at: now }
    attributes[:last_event_at] = [session.last_event_at, now].compact.max if answered_session?(session)
    session.update_columns(**attributes) # rubocop:disable Rails/SkipsModelValidations
  end

  def runtime_lease_metadata(now)
    {
      'owner' => runtime_owner,
      'runtime_session_id' => runtime_session_id,
      'heartbeat_at' => now.iso8601(3)
    }
  end

  def validate_payload!
    raise_invalid_heartbeat!('account_id is required') if payload['account_id'].blank? && payload['accountId'].blank?
    raise_invalid_heartbeat!('runtime_engine is required') if runtime_owner.blank?
    raise_invalid_heartbeat!('runtime_session_id is required') if runtime_session_id.blank?
  end

  def validate_runtime_lease_identity!(current_lease)
    current = current_lease.to_h.deep_stringify_keys
    owner_matches = current['owner'].blank? || current['owner'] == runtime_owner
    session_matches = current['runtime_session_id'].blank? || current['runtime_session_id'] == runtime_session_id
    return if owner_matches && session_matches

    raise Telephony::Error.new(
      code: 'RUNTIME_LEASE_CONFLICT',
      message: 'Runtime lease belongs to another runtime session',
      status: :conflict
    )
  end

  def runtime_owner
    payload['runtime_engine'].presence || payload['runtimeEngine'].presence
  end

  def runtime_session_id
    payload['runtime_session_id'].presence || payload['runtimeSessionId'].presence
  end

  def answered_session?(session)
    session.answered_at.present? || session.status == 'in_progress'
  end

  def raise_call_session_not_found!
    raise Telephony::Error.new(code: 'CALL_SESSION_NOT_FOUND', message: 'Unable to resolve call session for runtime heartbeat', status: :not_found)
  end

  def raise_invalid_heartbeat!(message)
    raise Telephony::Error.new(code: 'INVALID_HEARTBEAT', message: message, status: :unprocessable_content)
  end
end
