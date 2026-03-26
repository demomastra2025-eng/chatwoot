class Telephony::CallsService
  BRIDGE_STATUS_MAP = {
    'queued' => 'ringing',
    'initiated' => 'ringing',
    'ringing' => 'ringing',
    'answered' => 'in-progress',
    'in-progress' => 'in-progress',
    'inprogress' => 'in-progress',
    'completed' => 'completed',
    'busy' => 'no-answer',
    'no-answer' => 'no-answer',
    'failed' => 'failed',
    'rejected' => 'failed'
  }.freeze

  def initialize(account:, bridge_client: Telephony::BridgeClient.new)
    @account = account
    @bridge_client = bridge_client
  end

  def create_outbound!(inbox:, contact:, user:, conversation:)
    raise Telephony::Error.new(code: 'MISSING_PHONE_NUMBER', message: 'Contact phone number is required') if contact.phone_number.blank?

    number_binding = ensure_number_binding!(inbox)
    agent_binding = account.telephony_agent_bindings.find_by(user_id: user.id)

    response = bridge_client.post('/telephony/calls/outbound', outbound_payload(number_binding, inbox, contact, user, conversation, agent_binding))
    call_ref = extract_call_ref(response)
    raise Telephony::Error.new(code: 'INVALID_BRIDGE_RESPONSE', message: 'Telephony bridge did not return call_ref', status: :bad_gateway) if call_ref.blank?

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
      metadata: (call_session.metadata || {}).merge('bridge_response' => response)
    )
    call_session.save!

    {
      call_ref: call_ref,
      status: call_session.status,
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
      message: 'Voice inbox is not bound to a Fonoster number',
      status: :unprocessable_content
    )
  end

  def outbound_payload(number_binding, inbox, contact, user, conversation, agent_binding)
    {
      from_number_ref: number_binding.number_ref,
      to: contact.phone_number,
      app_ref: number_binding.effective_app_ref,
      conversation_id: conversation.id,
      contact_id: contact.id,
      metadata: {
        chatwoot_account_id: account.id,
        chatwoot_inbox_id: inbox.id,
        chatwoot_contact_id: contact.id,
        chatwoot_conversation_id: conversation.id,
        chatwoot_conversation_display_id: conversation.display_id,
        chatwoot_user_id: user.id,
        fonoster_agent_ref: agent_binding&.agent_ref
      }.compact
    }.compact
  end

  def extract_call_ref(response)
    response['call_ref'] || response['ref'] || response.dig('payload', 'call_ref') || response.dig('payload', 'ref')
  end

  def normalize_status(status)
    BRIDGE_STATUS_MAP[status.to_s.downcase] || 'ringing'
  end
end
