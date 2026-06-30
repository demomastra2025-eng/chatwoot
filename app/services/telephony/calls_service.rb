class Telephony::CallsService
  BRIDGE_STATUS_MAP = {
    'queued' => 'created',
    'initiated' => 'created',
    'ringing' => 'ringing',
    'connecting' => 'connecting',
    'answered' => 'in_progress',
    'in-progress' => 'in_progress',
    'in_progress' => 'in_progress',
    'inprogress' => 'in_progress',
    'completed' => 'completed',
    'missed' => 'missed',
    'busy' => 'busy',
    'no-answer' => 'no_answer',
    'no_answer' => 'no_answer',
    'cancelled' => 'cancelled',
    'canceled' => 'cancelled',
    'rejected' => 'rejected',
    'failed' => 'failed'
  }.freeze

  def initialize(account:, bridge_client: nil)
    @account = account
    @bridge_client = bridge_client || Telephony::BridgeClient.new(account_id: account.id)
  end

  def create_outbound!(inbox:, contact:, user:, conversation:)
    raise Telephony::Error.new(code: 'MISSING_PHONE_NUMBER', message: 'Contact phone number is required') if contact.phone_number.blank?

    number_binding = ensure_number_binding!(inbox)
    operator_identity = operator_identity_for(inbox, user)
    agent_binding = operator_identity&.agent_binding
    return create_sipuni_outbound!(number_binding, inbox, contact, user, conversation, operator_identity) if sipuni_inbox?(inbox)

    response = bridge_client.post(
      '/telephony/calls/outbound',
      outbound_payload(number_binding, inbox, contact, user, conversation, operator_identity)
    )
    call_ref = extract_call_ref(response)
    if call_ref.blank?
      raise Telephony::Error.new(code: 'INVALID_BRIDGE_RESPONSE', message: 'Telephony bridge did not return call_ref',
                                 status: :bad_gateway)
    end

    call_session = account.telephony_call_sessions.find_or_initialize_by(external_call_ref: call_ref)
    call_session.assign_attributes(
      conversation: conversation,
      contact: contact,
      inbox: inbox,
      number_binding: number_binding,
      agent_binding: agent_binding,
      provider: 'fonoster',
      status: normalize_status(response['status']),
      direction: 'outbound',
      from_number: number_binding.phone_number || inbox.channel&.phone_number,
      to_number: contact.phone_number,
      last_event_at: Time.current,
      metadata: (call_session.metadata || {}).merge(
        'bridge_response' => response,
        'fonoster_call_ref' => call_ref,
        'browser_join_supported' => browser_join_supported?(operator_identity),
        'operator_identity' => operator_identity_metadata(operator_identity)
      )
    )
    call_session.save!

    {
      call_ref: call_ref,
      status: call_session.status,
      browser_join_supported: browser_join_supported?(operator_identity),
      response: response,
      call_session: call_session
    }
  end

  def list_remote(filters = {})
    bridge_client.get('/telephony/calls', query: filters)
  end

  def find_remote(call_ref)
    bridge_client.get("/telephony/calls/#{call_ref}")
  end

  private

  attr_reader :account, :bridge_client

  def ensure_number_binding!(inbox)
    binding = inbox.telephony_number_binding
    binding ||= Telephony::NumberBinding.sync_from_voice_channel!(inbox.channel) if inbox.channel_type == 'Channel::Voice'
    return binding if binding.present?

    raise Telephony::Error.new(
      code: 'VOICE_INBOX_NOT_BOUND',
      message: 'Voice inbox is not bound to a telephony number',
      status: :unprocessable_content
    )
  end

  def outbound_payload(number_binding, inbox, contact, user, conversation, operator_identity)
    app_ref = outbound_app_ref(number_binding)
    recording_enabled = recording_enabled?(number_binding.routing_policy)
    operator_metadata = operator_identity_metadata(operator_identity)

    {
      from_number_ref: number_binding.number_ref,
      to: contact.phone_number,
      app_ref: app_ref,
      appRef: app_ref,
      operator_agent_ref: operator_identity&.agent_ref,
      operatorAgentRef: operator_identity&.agent_ref,
      operator_agent_aor: operator_identity&.agent_aor,
      operatorAgentAor: operator_identity&.agent_aor,
      recording_enabled: recording_enabled,
      recordingEnabled: recording_enabled,
      conversation_id: conversation.id,
      contact_id: contact.id,
      metadata: {
        chatwoot_account_id: account.id,
        chatwoot_inbox_id: inbox.id,
        chatwoot_contact_id: contact.id,
        chatwoot_conversation_id: conversation.id,
        chatwoot_conversation_display_id: conversation.display_id,
        chatwoot_user_id: user.id,
        recording_enabled: recording_enabled
      }.merge(operator_metadata).merge(
        browser_join_supported: browser_join_supported?(operator_identity)
      ).compact
    }.compact
  end

  def create_sipuni_outbound!(number_binding, inbox, contact, user, conversation, operator_identity)
    call_ref = "sipuni:local:#{SecureRandom.uuid}"
    from_number = number_binding.phone_number || inbox.channel&.phone_number
    metadata = sipuni_outbound_metadata(number_binding, inbox, contact, user, conversation, operator_identity, call_ref)

    call_session = account.telephony_call_sessions.find_or_initialize_by(external_call_ref: call_ref)
    call_session.assign_attributes(
      conversation: conversation,
      contact: contact,
      inbox: inbox,
      number_binding: number_binding,
      agent_binding: operator_identity&.agent_binding,
      provider: 'sipuni',
      status: 'created',
      direction: 'outbound',
      from_number: from_number,
      to_number: contact.phone_number,
      started_at: Time.current,
      last_event_at: Time.current,
      metadata: metadata
    )
    call_session.save!

    {
      call_ref: call_ref,
      status: call_session.status,
      browser_join_supported: browser_join_supported?(operator_identity),
      response: {
        'provider' => 'sipuni',
        'call_ref' => call_ref,
        'status' => call_session.status,
        'browser_join_supported' => browser_join_supported?(operator_identity)
      },
      call_session: call_session
    }
  end

  def sipuni_outbound_metadata(number_binding, inbox, contact, user, conversation, operator_identity, call_ref)
    operator_metadata = operator_identity_metadata(operator_identity)
    operator_route_metadata = sipuni_operator_route_metadata(operator_identity)
    {
      'sipuni_call_ref' => call_ref,
      'browser_join_supported' => browser_join_supported?(operator_identity),
      'operator_identity' => operator_metadata,
      'metadata' => {
        'source' => 'onelink_browser_janus_sip',
        'provider' => 'sipuni',
        'route_action' => 'operator',
        'direction' => 'outbound',
        'call_direction' => 'outbound',
        'chatwoot_account_id' => account.id,
        'chatwoot_inbox_id' => inbox.id,
        'chatwoot_contact_id' => contact.id,
        'chatwoot_conversation_id' => conversation.id,
        'chatwoot_conversation_display_id' => conversation.display_id,
        'chatwoot_user_id' => user.id,
        'number_ref' => number_binding.number_ref,
        'outbound_target_number' => contact.phone_number
      }.merge(operator_metadata.stringify_keys).merge(operator_route_metadata).compact
    }.compact
  end

  def sipuni_operator_route_metadata(operator_identity)
    profile = operator_identity&.sip_profile
    return {} if profile.blank?

    candidate = {
      'source' => 'sip_profile',
      'sip_profile_id' => profile.id,
      'user_id' => profile.user_id,
      'user_name' => profile.user&.name,
      'name' => profile.user&.name,
      'agent_ref' => operator_identity.agent_ref,
      'agent_aor' => operator_identity.agent_aor,
      'internal_extension' => profile.internal_extension
    }.compact

    {
      'operator_pool' => true,
      'operator_pool_size' => 1,
      'operator_internal_extension' => profile.internal_extension,
      'operator_candidates' => [candidate],
      'operator_candidate_sip_profile_ids' => [profile.id],
      'operator_candidate_user_ids' => [profile.user_id],
      'operator_candidate_agent_refs' => [operator_identity.agent_ref],
      'operator_candidate_agent_aors' => [operator_identity.agent_aor],
      'operator_candidate_sources' => ['sip_profile']
    }.compact
  end

  def sipuni_inbox?(inbox)
    inbox&.channel&.provider == 'sipuni'
  end

  def operator_identity_for(inbox, user)
    Telephony::OperatorIdentityResolver.new(account: account, inbox: inbox, user: user).resolve
  end

  def operator_identity_metadata(operator_identity)
    operator_identity&.metadata || {}
  end

  def browser_join_supported?(operator_identity)
    operator_identity.present? && operator_identity.browser_join_supported?
  end

  def recording_enabled?(routing_policy)
    settings = (routing_policy&.ai_voice_settings || {}).deep_stringify_keys
    return ActiveModel::Type::Boolean.new.cast(settings['recording_enabled']) if settings.key?('recording_enabled')

    true
  end

  def outbound_app_ref(number_binding)
    number_binding.effective_app_ref.presence ||
      ENV.fetch('TELEPHONY_BRIDGE_RUNTIME_APP_REF', nil).presence ||
      ENV.fetch('TELEPHONY_BRIDGE_DEFAULT_APP_REF', nil).presence
  end

  def extract_call_ref(response)
    response['call_ref'] || response['ref'] || response.dig('payload', 'call_ref') || response.dig('payload', 'ref')
  end

  def normalize_status(status)
    mapped = BRIDGE_STATUS_MAP[status.to_s.downcase]
    Telephony::CallSession.normalize_status(mapped || status) || 'ringing'
  end
end
