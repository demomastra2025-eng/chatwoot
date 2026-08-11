require 'digest'
require 'json'
require 'securerandom'

class Telephony::AiVoice::ToolExecutionService
  EVENT_TYPE = 'ai_tool_execution'.freeze
  RESULT_PURPOSE = 'ai_voice_tool_result'.freeze
  EXECUTION_LEASE = 3.minutes
  RESULT_TTL = 6.hours
  MAX_ENCRYPTED_RESULT_BYTES = 64.kilobytes

  def initialize(tool_name:, payload:)
    @tool_name = tool_name.to_s.strip
    @payload = payload.deep_stringify_keys
    @owner_token = SecureRandom.uuid
  end

  def perform
    validate_request!
    verify_tool_capability!

    event, owner = reserve_event!
    return replay_event(event) unless owner

    @owned_event = event
    raise_call_session_terminal! if call_session.terminal?
    mark_execution_started!(event)
    result = dispatch_with_current_capability!
    if business_failure_result?(result)
      complete_business_failure_event!(event, result)
    else
      complete_event!(event, result)
    end
    result
  rescue StandardError => e
    fail_owned_event!(e, outcome_unknown: dispatch_outcome_unknown?(e))
    raise
  end

  private

  attr_reader :tool_name, :payload, :owner_token

  def dispatch_service
    @dispatch_service ||= Telephony::AiVoice::ToolDispatchService.new(tool_name: tool_name, payload: payload)
  end

  def call_session
    return @call_session if defined?(@call_session)

    @call_session = Telephony::AiVoice::CallSessionResolver.new(payload: payload).call_session
    if @call_session.blank?
      raise Telephony::Error.new(
        code: 'CALL_SESSION_NOT_FOUND',
        message: 'Unable to resolve account-scoped call session',
        status: :not_found
      )
    end

    @call_session
  end

  def validate_request!
    raise_request_error!('ACCOUNT_SCOPE_REQUIRED', 'account_id is required') if payload['account_id'].blank? && payload['accountId'].blank?
    raise_request_error!('TOOL_IDEMPOTENCY_KEY_REQUIRED', 'tool_call_id or idempotency_key is required') if idempotency_key.blank?
  end

  def verify_tool_capability!(assistant_id: dispatch_service.captain_assistant_id)
    Telephony::AiVoice::ToolCapability.verify!(
      token: tool_capability_token,
      call_session: call_session,
      assistant_id: assistant_id,
      tool_name: tool_name,
      payload: payload
    )
  end

  def dispatch_with_current_capability!
    dispatch_service.with_captain_assistant_assignment_lock do |assistant_id|
      verify_tool_capability!(assistant_id: assistant_id)
      @dispatch_started = true
      result = normalize_result(dispatch_service.perform)
      @dispatch_started = false
      result
    end
  end

  def tool_capability_token
    payload['tool_capability'].presence || payload['toolCapability'].presence
  end

  def idempotency_key
    @idempotency_key ||= payload['idempotency_key'].presence || payload['tool_call_id'].presence || payload['request_id'].presence
  end

  def event_key
    @event_key ||= "ai-tool:#{call_session.id}:#{Digest::SHA256.hexdigest(idempotency_key.to_s)}"
  end

  def request_fingerprint
    @request_fingerprint ||= Digest::SHA256.hexdigest(
      JSON.generate(deep_sort('tool_name' => tool_name, 'arguments' => payload['arguments'].to_h.deep_stringify_keys))
    )
  end

  def reserve_event!
    scope = call_session.account.telephony_events.where(event_key: event_key)
    event = nil
    owner = false

    Telephony::Event.transaction do
      event = scope.lock.first
      if event.present?
        validate_event_request!(event)
        owner = reclaim_stale_reservation!(event)
      else
        event = scope.create!(
          call_session: call_session,
          event_type: EVENT_TYPE,
          status: 'received',
          payload: event_payload(phase: 'reserved')
        )
        owner = true
      end
    end
    [event, owner]
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    event = scope.first
    raise if event.blank?

    validate_event_request!(event)
    [event, false]
  end

  def reclaim_stale_reservation!(event)
    return false unless event.status == 'received'

    stored_payload = event.payload.to_h.deep_stringify_keys
    return false unless execution_lease_expired?(event, stored_payload)

    if stored_payload['phase'] == 'reserved'
      event.update!(payload: event_payload(phase: 'reserved'))
      return true
    end

    event.update!(
      status: 'failed',
      processed_at: Time.current,
      error_message: 'TOOL_EXECUTION_OUTCOME_UNKNOWN',
      payload: stored_payload.except('owner_token_hash', 'lease_expires_at').merge(
        'phase' => 'outcome_unknown',
        'error_code' => 'TOOL_EXECUTION_OUTCOME_UNKNOWN'
      )
    )
    false
  end

  def replay_event(event)
    validate_event_request!(event)
    stored_payload = event.payload.to_h.deep_stringify_keys
    return decrypt_result!(stored_payload) if event.processed?
    return decrypt_result!(stored_payload) if stored_payload['phase'] == 'business_failed'

    if stored_payload['phase'] == 'outcome_unknown'
      raise Telephony::Error.new(
        code: 'TOOL_EXECUTION_OUTCOME_UNKNOWN',
        message: 'tool execution may have completed before the runtime lost its acknowledgement',
        status: :conflict
      )
    end

    code = event.failed? ? 'TOOL_EXECUTION_PREVIOUSLY_FAILED' : 'TOOL_EXECUTION_IN_PROGRESS'
    message = event.failed? ? 'tool execution previously failed and will not be replayed automatically' : 'tool execution is already in progress'
    raise Telephony::Error.new(code: code, message: message, status: :conflict)
  end

  def validate_event_request!(event)
    stored_payload = event.payload.to_h.deep_stringify_keys
    return if stored_payload['tool_name'] == tool_name && stored_payload['request_fingerprint'] == request_fingerprint

    raise Telephony::Error.new(
      code: 'TOOL_IDEMPOTENCY_CONFLICT',
      message: 'idempotency key was already used for a different tool request',
      status: :conflict
    )
  end

  def mark_execution_started!(event)
    event.with_lock do
      validate_event_ownership!(event)
      event.update!(payload: event_payload(phase: 'executing'))
    end
  end

  def complete_event!(event, result)
    event.with_lock do
      validate_event_ownership!(event)
      event.update!(
        status: 'processed',
        processed_at: Time.current,
        error_message: nil,
        payload: completed_event_payload(result)
      )
    end
  end

  def complete_business_failure_event!(event, result)
    event.with_lock do
      validate_event_ownership!(event)
      event.update!(
        status: 'failed',
        processed_at: Time.current,
        error_message: result['code'],
        payload: completed_event_payload(result).merge('phase' => 'business_failed')
      )
    end
  end

  def fail_owned_event!(error, outcome_unknown: false)
    return if @owned_event.blank? || !@owned_event.persisted?

    @owned_event.with_lock do
      next unless owned_event?(@owned_event) && !@owned_event.processed?

      @owned_event.update!(failure_event_attributes(error, outcome_unknown: outcome_unknown))
    end
  rescue ActiveRecord::ActiveRecordError
    nil
  end

  def failure_event_attributes(error, outcome_unknown:)
    code = outcome_unknown ? 'TOOL_EXECUTION_OUTCOME_UNKNOWN' : safe_error_code(error)
    {
      status: 'failed',
      processed_at: Time.current,
      error_message: code,
      payload: failure_event_payload(error, code, outcome_unknown: outcome_unknown)
    }
  end

  def failure_event_payload(error, code, outcome_unknown:)
    payload = base_event_payload.merge('phase' => outcome_unknown ? 'outcome_unknown' : 'failed', 'error_code' => code)
    return payload unless outcome_unknown

    payload.merge('dispatch_error_class' => error.class.name.to_s.first(120))
  end

  def completed_event_payload(result)
    serialized = JSON.generate(result)
    payload = base_event_payload.merge(
      'phase' => 'completed',
      'result_digest' => Digest::SHA256.hexdigest(serialized),
      'result_bytes' => serialized.bytesize,
      'result_keys' => result.is_a?(Hash) ? result.keys.map(&:to_s).sort.first(50) : []
    )
    return payload if serialized.bytesize > MAX_ENCRYPTED_RESULT_BYTES

    payload.merge('result_ciphertext' => result_encryptor.encrypt_and_sign(serialized, purpose: RESULT_PURPOSE, expires_in: RESULT_TTL))
  end

  def business_failure_result?(result)
    return false unless result.is_a?(Hash)

    normalized = result.with_indifferent_access
    normalized[:status] == 'failed' && normalized[:error].present?
  end

  def dispatch_outcome_unknown?(_error)
    @dispatch_started == true
  end

  def decrypt_result!(stored_payload)
    ciphertext = stored_payload['result_ciphertext'].presence
    raise_result_unavailable! if ciphertext.blank?

    serialized = result_encryptor.decrypt_and_verify(ciphertext, purpose: RESULT_PURPOSE)
    raise_result_unavailable! unless Digest::SHA256.hexdigest(serialized) == stored_payload['result_digest']

    JSON.parse(serialized)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage, JSON::ParserError
    raise_result_unavailable!
  end

  def result_encryptor
    @result_encryptor ||= begin
      cipher = 'aes-256-gcm'
      key = Rails.application.key_generator.generate_key('ai_voice_tool_result:v1', ActiveSupport::MessageEncryptor.key_len(cipher))
      ActiveSupport::MessageEncryptor.new(key, cipher: cipher)
    end
  end

  def event_payload(phase:)
    base_event_payload.merge(
      'phase' => phase,
      'owner_token_hash' => owner_token_hash,
      'lease_expires_at' => (Time.current + EXECUTION_LEASE).iso8601(3)
    )
  end

  def base_event_payload
    {
      'tool_name' => tool_name,
      'request_fingerprint' => request_fingerprint,
      'idempotency_key_hash' => Digest::SHA256.hexdigest(idempotency_key.to_s)
    }
  end

  def validate_event_ownership!(event)
    return if owned_event?(event) && event.status == 'received'

    raise Telephony::Error.new(
      code: 'TOOL_EXECUTION_LEASE_LOST',
      message: 'tool execution lease is no longer owned by this runtime',
      status: :conflict
    )
  end

  def owned_event?(event)
    event.reload.payload.to_h['owner_token_hash'].to_s == owner_token_hash
  end

  def owner_token_hash
    @owner_token_hash ||= Digest::SHA256.hexdigest(owner_token)
  end

  def execution_lease_expired?(event, stored_payload)
    lease_expires_at = Time.iso8601(stored_payload['lease_expires_at'].to_s)
    lease_expires_at <= Time.current
  rescue ArgumentError
    event.created_at <= Time.current - EXECUTION_LEASE
  end

  def normalize_result(result)
    JSON.parse(JSON.generate(result.as_json))
  end

  def safe_error_code(error)
    return error.code.to_s.first(120) if error.respond_to?(:code) && error.code.present?

    error.class.name.to_s.underscore.upcase.first(120)
  end

  def raise_result_unavailable!
    raise Telephony::Error.new(
      code: 'TOOL_RESULT_UNAVAILABLE',
      message: 'tool completed but its replay payload is unavailable; execution will not be repeated',
      status: :conflict
    )
  end

  def raise_call_session_terminal!
    raise Telephony::Error.new(code: 'CALL_SESSION_TERMINAL', message: 'tool execution is not allowed for a terminal call', status: :conflict)
  end

  def raise_request_error!(code, message)
    raise Telephony::Error.new(code: code, message: message, status: :unprocessable_content)
  end

  def deep_sort(value)
    case value
    when Hash
      stringified = value.deep_stringify_keys
      stringified.keys.sort.index_with { |key| deep_sort(stringified[key]) }
    when Array
      value.map { |entry| deep_sort(entry) }
    else
      value
    end
  end
end
