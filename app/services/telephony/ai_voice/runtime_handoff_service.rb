class Telephony::AiVoice::RuntimeHandoffService
  SOURCE_RUNTIME = 'pipecat'.freeze
  TARGET_RUNTIME = 'onelink-ai-voice-node'.freeze
  HANDOFF_HISTORY_LIMIT = 10
  RUNTIME_LEASE_MAX_AGE = Telephony::AiVoice::ToolCapability::RUNTIME_LEASE_MAX_AGE

  def initialize(payload:)
    @payload = payload.deep_stringify_keys
  end

  def perform
    validate_payload!
    session = call_session
    raise_call_session_not_found! if session.blank?
    validate_call_reference!(session)

    status, generation = handoff_runtime!(session)
    handoff_response(session, status, generation)
  end

  private

  attr_reader :payload

  def handoff_runtime!(session)
    session.with_lock do
      raise_terminal_call! if session.terminal?

      metadata = session.metadata.to_h.deep_stringify_keys
      current_lease = metadata['runtime_lease'].to_h.deep_stringify_keys
      if target_lease?(current_lease)
        ['already_handed_off', current_lease['generation']]
      else
        validate_source_lease!(current_lease)
        ['handed_off', persist_handoff!(session, metadata)]
      end
    end
  end

  def handoff_response(session, status, generation)
    {
      status: status,
      call_session_id: session.id,
      runtime_engine: TARGET_RUNTIME,
      runtime_session_id: runtime_session_id,
      runtime_generation: generation
    }
  end

  def persist_handoff!(session, metadata)
    now = Time.current
    generation = SecureRandom.uuid
    metadata['runtime_lease'] = target_runtime_lease(now, generation)
    metadata['runtime_handoffs'] = runtime_handoff_history(metadata, now, generation)
    session.update_columns(metadata: metadata, updated_at: now) # rubocop:disable Rails/SkipsModelValidations
    generation
  end

  def target_runtime_lease(now, generation)
    {
      'owner' => TARGET_RUNTIME,
      'runtime_session_id' => runtime_session_id,
      'generation' => generation,
      'source_runtime_generation' => source_runtime_generation,
      'heartbeat_at' => now.iso8601(3)
    }
  end

  def call_session
    Telephony::AiVoice::CallSessionResolver.new(payload: payload).call_session
  end

  def validate_payload!
    raise_invalid_handoff!('account_id is required') if payload['account_id'].blank? && payload['accountId'].blank?
    raise_invalid_handoff!('source runtime must be pipecat') unless source_runtime == SOURCE_RUNTIME
    raise_invalid_handoff!('target runtime must be onelink-ai-voice-node') unless target_runtime == TARGET_RUNTIME
    validate_runtime_identity!
  end

  def validate_runtime_identity!
    raise_invalid_handoff!('runtime_session_id is required') if runtime_session_id.blank?
    raise_invalid_handoff!('source_runtime_generation is required') if source_runtime_generation.blank?
    return if source_runtime_session_id == runtime_session_id

    raise_invalid_handoff!('source and target runtime_session_id must match')
  end

  def validate_source_lease!(lease)
    owner_matches = lease['owner'] == SOURCE_RUNTIME
    session_matches = lease['runtime_session_id'] == source_runtime_session_id
    generation_matches = lease['generation'].present? && lease['generation'] == source_runtime_generation
    raise_runtime_lease_conflict! unless owner_matches && session_matches && generation_matches

    heartbeat_at = Time.iso8601(lease['heartbeat_at'].to_s)
    raise_runtime_lease_expired! if heartbeat_at < Time.current - RUNTIME_LEASE_MAX_AGE
  rescue ArgumentError
    raise_runtime_lease_conflict!
  end

  def target_lease?(lease)
    lease['owner'] == TARGET_RUNTIME &&
      lease['runtime_session_id'] == runtime_session_id &&
      lease['generation'].present? &&
      lease['source_runtime_generation'] == source_runtime_generation
  end

  def runtime_handoff_history(metadata, now, generation)
    history = Array(metadata['runtime_handoffs']).last(HANDOFF_HISTORY_LIMIT - 1)
    history << {
      'from' => SOURCE_RUNTIME,
      'to' => TARGET_RUNTIME,
      'runtime_session_id' => runtime_session_id,
      'source_runtime_generation' => source_runtime_generation,
      'runtime_generation' => generation,
      'reason' => reason,
      'occurred_at' => now.iso8601(3)
    }.compact
  end

  def source_runtime
    payload['source_runtime_engine'].presence || payload['sourceRuntimeEngine'].presence
  end

  def target_runtime
    payload['target_runtime_engine'].presence || payload['targetRuntimeEngine'].presence
  end

  def source_runtime_session_id
    payload['source_runtime_session_id'].presence || payload['sourceRuntimeSessionId'].presence
  end

  def runtime_session_id
    payload['runtime_session_id'].presence || payload['runtimeSessionId'].presence
  end

  def source_runtime_generation
    payload['source_runtime_generation'].presence || payload['sourceRuntimeGeneration'].presence
  end

  def call_ref
    payload['call_ref'].presence || payload['callRef'].presence
  end

  def validate_call_reference!(session)
    return if call_ref.blank? || session.external_call_ref == call_ref

    raise Telephony::Error.new(
      code: 'CALL_SESSION_REFERENCE_MISMATCH',
      message: 'call_session_id and call_ref resolve to different calls',
      status: :unprocessable_content
    )
  end

  def reason
    value = payload['reason'].to_s.gsub(/[^a-zA-Z0-9_.:-]+/, '_').first(160)
    value.presence
  end

  def raise_call_session_not_found!
    raise Telephony::Error.new(
      code: 'CALL_SESSION_NOT_FOUND',
      message: 'Unable to resolve call session for runtime handoff',
      status: :not_found
    )
  end

  def raise_terminal_call!
    raise Telephony::Error.new(
      code: 'CALL_SESSION_TERMINAL',
      message: 'Runtime handoff is not allowed for a terminal call',
      status: :conflict
    )
  end

  def raise_invalid_handoff!(message)
    raise Telephony::Error.new(code: 'INVALID_RUNTIME_HANDOFF', message: message, status: :unprocessable_content)
  end

  def raise_runtime_lease_conflict!
    raise Telephony::Error.new(
      code: 'RUNTIME_LEASE_CONFLICT',
      message: 'Runtime lease belongs to another runtime generation',
      status: :conflict
    )
  end

  def raise_runtime_lease_expired!
    raise Telephony::Error.new(code: 'RUNTIME_LEASE_EXPIRED', message: 'Runtime lease has expired', status: :conflict)
  end
end
