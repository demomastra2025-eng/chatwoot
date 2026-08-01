require 'digest'
require 'json'
require 'securerandom'

class Telephony::AiVoice::ToolCapability
  PURPOSE = 'ai_voice_tool_execution'.freeze
  VERSION = 1
  DEFAULT_TTL = 20.minutes
  MAX_TTL = 4.hours
  RUNTIME_LEASE_MAX_AGE = 90.seconds

  class << self
    def issue(call_session:, runtime_session_id:, runtime_engine:, assistant_id:, tools:, expires_in: DEFAULT_TTL)
      new(
        call_session: call_session,
        runtime_session_id: runtime_session_id,
        runtime_engine: runtime_engine,
        assistant_id: assistant_id
      ).issue(tools: tools, expires_in: expires_in)
    end

    def verify!(token:, call_session:, assistant_id:, tool_name:, payload:)
      new(
        call_session: call_session,
        runtime_session_id: payload['runtime_session_id'].presence || payload['runtimeSessionId'].presence,
        runtime_engine: payload['runtime_engine'].presence || payload['runtimeEngine'].presence,
        assistant_id: assistant_id
      ).verify!(token: token, tool_name: tool_name, payload: payload.deep_stringify_keys)
    end

    private

    def verifier
      @verifier ||= ActiveSupport::MessageVerifier.new(
        Rails.application.key_generator.generate_key('ai_voice_tool_capability:v1', 64),
        digest: 'SHA256',
        serializer: JSON
      )
    end
  end

  def initialize(call_session:, runtime_session_id:, runtime_engine:, assistant_id:)
    @call_session = call_session
    @runtime_session_id = runtime_session_id.to_s.strip
    @runtime_engine = runtime_engine.to_s.strip
    @assistant_id = assistant_id
  end

  def issue(tools:, expires_in: DEFAULT_TTL)
    validate_runtime_identity!
    generation = establish_runtime_lease!
    names = Array(tools).filter_map { |tool| tool.to_h.with_indifferent_access[:name].to_s.strip.presence }.uniq.sort
    raise_capability_error!('TOOL_CAPABILITY_EMPTY', 'voice context has no executable tools') if names.empty?

    self.class.send(:verifier).generate(
      capability_payload(generation: generation, tool_names: names),
      purpose: PURPOSE,
      expires_in: bounded_ttl(expires_in)
    )
  end

  def verify!(token:, tool_name:, payload:)
    validate_runtime_identity!
    data = self.class.send(:verifier).verified(token.to_s, purpose: PURPOSE)
    raise_capability_error!('TOOL_CAPABILITY_INVALID', 'tool capability is missing, invalid, or expired') unless data.is_a?(Hash)

    capability = data.deep_stringify_keys
    validate_capability_scope!(capability, payload)
    validate_runtime_lease!(capability)
    unless Array(capability['tool_names']).include?(tool_name.to_s)
      raise_capability_error!('TOOL_NOT_ALLOWED_FOR_RUNTIME', 'tool was not enabled for this voice runtime')
    end

    capability
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    raise_capability_error!('TOOL_CAPABILITY_INVALID', 'tool capability is missing, invalid, or expired')
  end

  private

  attr_reader :call_session, :runtime_session_id, :runtime_engine, :assistant_id

  def validate_runtime_identity!
    if runtime_session_id.blank? || runtime_engine.blank?
      raise_capability_error!('RUNTIME_IDENTITY_REQUIRED', 'runtime_session_id and runtime_engine are required')
    end
    return if call_session.tenant_links_match?(call_session.account)

    raise_capability_error!('CALL_SESSION_TENANT_MISMATCH', 'call session tenant links are inconsistent')
  end

  def establish_runtime_lease!
    generation = nil
    call_session.with_lock do
      raise_capability_error!('CALL_SESSION_TERMINAL', 'tool capability cannot be issued for a terminal call') if call_session.terminal?

      metadata = call_session.metadata.to_h.deep_stringify_keys
      lease = metadata['runtime_lease'].to_h.deep_stringify_keys
      validate_lease_identity!(lease) if lease.present?
      generation = lease['generation'].presence || SecureRandom.uuid
      metadata['runtime_lease'] = lease.merge(
        'owner' => runtime_engine,
        'runtime_session_id' => runtime_session_id,
        'generation' => generation,
        'heartbeat_at' => Time.current.iso8601(3)
      )
      call_session.update_columns(metadata: metadata, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end
    generation
  end

  def validate_capability_scope!(capability, payload)
    expected = {
      'version' => VERSION.to_s,
      'account_id' => call_session.account_id.to_s,
      'call_session_id' => call_session.id.to_s,
      'call_ref' => call_session.external_call_ref.to_s,
      'runtime_session_id' => runtime_session_id,
      'runtime_engine' => runtime_engine,
      'assistant_id' => assistant_id.to_s,
      'conversation_id' => call_session.conversation_id.to_s,
      'inbox_id' => call_session.inbox_id.to_s
    }
    provided = {
      'version' => capability['version'].to_s,
      'account_id' => payload['account_id'].presence || payload['accountId'].presence,
      'call_session_id' => payload['call_session_id'].presence || payload['callSessionId'].presence ||
                           payload['call_id'].presence || payload['callId'].presence,
      'call_ref' => payload['call_ref'].presence || payload['callRef'].presence,
      'runtime_session_id' => runtime_session_id,
      'runtime_engine' => runtime_engine,
      'assistant_id' => payload['assistant_id'].presence || payload['assistantId'].presence,
      'conversation_id' => payload['conversation_id'].presence || payload['conversationId'].presence,
      'inbox_id' => payload['inbox_id'].presence || payload['inboxId'].presence
    }.transform_values(&:to_s)

    capability_scope = capability.slice(*expected.keys).transform_values(&:to_s)
    return if capability_scope == expected && provided == expected

    raise_capability_error!('TOOL_CAPABILITY_SCOPE_MISMATCH', 'tool capability does not match the call runtime scope')
  end

  def validate_runtime_lease!(capability)
    lease = call_session.reload.metadata.to_h['runtime_lease'].to_h.deep_stringify_keys
    validate_lease_identity!(lease)
    unless lease['generation'].to_s == capability['runtime_generation'].to_s
      raise_capability_error!('RUNTIME_LEASE_CONFLICT', 'tool capability belongs to another runtime generation')
    end

    heartbeat_at = Time.iso8601(lease['heartbeat_at'].to_s)
    raise_capability_error!('RUNTIME_LEASE_EXPIRED', 'voice runtime lease has expired') if heartbeat_at < Time.current - RUNTIME_LEASE_MAX_AGE
  rescue ArgumentError
    raise_capability_error!('RUNTIME_LEASE_INVALID', 'voice runtime lease timestamp is invalid')
  end

  def validate_lease_identity!(lease)
    owner_matches = lease['owner'].to_s == runtime_engine
    session_matches = lease['runtime_session_id'].to_s == runtime_session_id
    return if owner_matches && session_matches

    raise_capability_error!('RUNTIME_LEASE_CONFLICT', 'runtime lease belongs to another voice runtime')
  end

  def capability_payload(generation:, tool_names:)
    {
      'version' => VERSION,
      'account_id' => call_session.account_id,
      'call_session_id' => call_session.id,
      'call_ref' => call_session.external_call_ref,
      'conversation_id' => call_session.conversation_id,
      'inbox_id' => call_session.inbox_id,
      'runtime_session_id' => runtime_session_id,
      'runtime_engine' => runtime_engine,
      'assistant_id' => assistant_id,
      'runtime_generation' => generation,
      'tool_names' => tool_names,
      'tool_catalog_digest' => Digest::SHA256.hexdigest(JSON.generate(tool_names)),
      'issued_at' => Time.current.iso8601(3)
    }
  end

  def bounded_ttl(expires_in)
    expires_in.to_i.seconds.clamp(1.minute, MAX_TTL)
  end

  def raise_capability_error!(code, message)
    raise Telephony::Error.new(code: code, message: message, status: :forbidden)
  end
end
