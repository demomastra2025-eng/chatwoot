class Telephony::CallsService
  PROVIDER_OWNED_SIP_PROVIDERS = %w[asterisk_analog sipuni binotel].freeze

  def initialize(account:)
    @account = account
  end

  def create_outbound!(inbox:, contact:, user:, conversation:)
    raise Telephony::Error.new(code: 'MISSING_PHONE_NUMBER', message: 'Contact phone number is required') if contact.phone_number.blank?

    Telephony::OperatorBusyService.new(account: account, user: user).with_lock do
      number_binding = ensure_number_binding!(inbox)
      operator_identity = operator_identity_for(inbox, user)
      if provider_owned_sip_inbox?(inbox)
        create_provider_owned_sip_outbound!(
          number_binding, inbox, contact, user, conversation, operator_identity
        )
      else
        raise Telephony::Error.new(
          code: 'UNSUPPORTED_TELEPHONY_PROVIDER',
          message: 'Outbound calls are supported only for Janus SIP voice providers',
          status: :unprocessable_content,
          details: { provider: inbox&.channel&.provider }
        )
      end
    end
  end

  def list_remote(_filters = {})
    { 'items' => [] }
  end

  def find_remote(_call_ref)
    nil
  end

  private

  attr_reader :account

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

  def create_provider_owned_sip_outbound!(number_binding, inbox, contact, user, conversation, operator_identity)
    provider = inbox.channel.provider
    call_ref = "#{provider}:local:#{SecureRandom.uuid}"
    from_number = number_binding.phone_number || inbox.channel&.phone_number
    metadata = provider_owned_sip_outbound_metadata(number_binding, inbox, contact, user, conversation, operator_identity, call_ref)

    call_session = account.telephony_call_sessions.find_or_initialize_by(external_call_ref: call_ref)
    call_session.assign_attributes(
      conversation: conversation,
      contact: contact,
      inbox: inbox,
      number_binding: number_binding,
      agent_binding: operator_identity&.agent_binding,
      provider: provider,
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
        'provider' => provider,
        'call_ref' => call_ref,
        'status' => call_session.status,
        'browser_join_supported' => browser_join_supported?(operator_identity)
      },
      call_session: call_session
    }
  end

  def provider_owned_sip_outbound_metadata(number_binding, inbox, contact, user, conversation, operator_identity, call_ref)
    provider = inbox.channel.provider
    operator_metadata = operator_identity_metadata(operator_identity)
    operator_route_metadata = provider_owned_sip_operator_route_metadata(operator_identity)
    {
      'telephony_call_ref' => call_ref,
      'browser_join_supported' => browser_join_supported?(operator_identity),
      'operator_identity' => operator_metadata,
      'metadata' => {
        'source' => 'onelink_browser_janus_sip',
        'provider' => provider,
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

  def provider_owned_sip_operator_route_metadata(operator_identity)
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

  def provider_owned_sip_inbox?(inbox)
    inbox&.channel&.provider.to_s.in?(PROVIDER_OWNED_SIP_PROVIDERS)
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
end
