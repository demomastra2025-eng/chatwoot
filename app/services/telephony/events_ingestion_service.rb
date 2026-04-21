require 'digest'

class Telephony::EventsIngestionService
  EVENT_STATUS_MAP = {
    'session_started' => 'ringing',
    'decision_received' => 'ringing',
    'dial_status' => nil,
    'session_completed' => 'completed',
    'session_failed' => 'failed',
    'unsupported_action' => 'failed',
    'ringing' => 'ringing',
    'answered' => 'in-progress',
    'in-progress' => 'in-progress',
    'completed' => 'completed',
    'failed' => 'failed',
    'busy' => 'no-answer',
    'no-answer' => 'no-answer',
    'rejected' => 'failed'
  }.freeze

  def initialize(payload:)
    @payload = payload.deep_stringify_keys
  end

  def perform
    account = resolve_account!
    event = persist_event!(account)
    return event.call_session if event.processed? && event.call_session.present?

    call_session = nil

    ActiveRecord::Base.transaction do
      call_session = upsert_call_session!(resolve_call_session!(account), account)
      ensure_conversation!(call_session, account)
      apply_call_status!(call_session)
      sync_voice_message!(call_session)
      event.update!(call_session: call_session, status: 'processed', processed_at: Time.current, error_message: nil)
    end

    call_session
  rescue StandardError => e
    event&.update(status: 'failed', error_message: e.message) if defined?(event) && event.present? && event.persisted?
    raise
  end

  private

  attr_reader :payload

  def persist_event!(account)
    event = find_or_create_event!(account)
    return event if event.processed?

    updates = {}
    updates[:event_type] = resolved_event_type if event.event_type != resolved_event_type
    updates[:payload] = payload if event.payload != payload
    event.update!(updates) if updates.any?
    event
  end

  def resolve_account!
    account_id = payload_value('account_id', 'accountId') || metadata_value('chatwoot_account_id', 'account_id', 'accountId')
    return Account.find(account_id) if account_id.present?

    conversation = resolve_metadata_conversation
    return conversation.account if conversation.present?

    inbox = resolve_metadata_inbox
    return inbox.account if inbox.present?

    contact = resolve_metadata_contact
    return contact.account if contact.present?

    session = Telephony::CallSession.find_by(external_call_ref: call_ref)
    return session.account if session.present?

    binding = resolve_number_binding
    return binding.account if binding.present?

    channel = Channel::Voice.find_by(phone_number: inbound_number)
    return channel.account if channel.present?

    raise Telephony::Error.new(code: 'ACCOUNT_NOT_FOUND', message: 'Unable to resolve account for telephony event', status: :not_found)
  end

  def resolve_call_session!(account)
    raise Telephony::Error.new(code: 'CALL_REF_REQUIRED', message: 'call_ref is required', status: :unprocessable_content) if call_ref.blank?

    account.telephony_call_sessions.find_by(external_call_ref: call_ref) ||
      account.telephony_call_sessions.build(external_call_ref: call_ref)
  end

  def upsert_call_session!(call_session, account)
    persist_call_session!(account, call_session) do |current_call_session|
      call_session_attributes(account, current_call_session)
    end
  end

  def call_session_attributes(account, call_session)
    conversation = resolve_existing_conversation(account, call_session)
    inbox = resolve_inbox(account)
    number_binding = resolve_number_binding || inbox&.telephony_number_binding
    contact = resolve_contact(account, conversation)
    agent_binding = resolve_agent_binding(account)

    attributes = {
      account: account,
      conversation: conversation || call_session.conversation,
      contact: contact || call_session.contact,
      inbox: inbox || call_session.inbox,
      number_binding: number_binding || call_session.number_binding,
      agent_binding: agent_binding || call_session.agent_binding,
      provider: payload_value('provider') || call_session.provider || 'fonoster',
      provider_call_sid: payload_value('provider_call_sid', 'providerCallSid', 'provider_call_id', 'providerCallId') || call_session.provider_call_sid,
      status: resolved_status || call_session.status,
      direction: resolved_direction || call_session.direction || 'inbound',
      from_number: resolved_from_number || call_session.from_number,
      to_number: resolved_to_number || call_session.to_number,
      recording_ref: payload_value('recording_ref', 'recordingRef') || call_session.recording_ref,
      transcript_ref: payload_value('transcript_ref', 'transcriptRef') || call_session.transcript_ref,
      summary: payload_value('summary') || call_session.summary,
      duration_seconds: resolved_duration || call_session.duration_seconds,
      started_at: resolved_started_at || call_session.started_at,
      ended_at: resolved_ended_at || call_session.ended_at,
      last_event_at: resolved_occurred_at || Time.current,
      metadata: merged_metadata(call_session)
    }
  end

  def ensure_conversation!(call_session, account)
    return if call_session.conversation.present?
    return unless call_session.direction == 'inbound'

    inbox = call_session.inbox || resolve_inbox(account)
    raise Telephony::Error.new(code: 'VOICE_INBOX_NOT_FOUND', message: 'Unable to resolve voice inbox for inbound call', status: :not_found) if inbox.blank?

    conversation = Voice::InboundCallBuilder.perform!(
      account: account,
      inbox: inbox,
      from_number: caller_number,
      call_sid: call_ref
    )

    call_session.update!(
      conversation: conversation,
      contact: conversation.contact,
      inbox: inbox,
      number_binding: inbox.telephony_number_binding || call_session.number_binding
    )
  end

  def apply_call_status!(call_session)
    conversation = call_session.conversation
    return unless conversation.present? && resolved_status.present?

    timestamp = call_session.ended_at&.to_i || call_session.started_at&.to_i
    Voice::CallStatus::Manager.new(
      conversation: conversation,
      call_sid: call_session.external_call_ref
    ).process_status_update(
      call_session.status,
      duration: call_session.duration_seconds,
      timestamp: timestamp
    )

    attrs = (conversation.additional_attributes || {}).deep_dup
    attrs['telephony_provider'] = call_session.provider
    attrs['recording_ref'] = call_session.recording_ref if call_session.recording_ref.present?
    attrs['transcript_ref'] = call_session.transcript_ref if call_session.transcript_ref.present?
    attrs['summary'] = call_session.summary if call_session.summary.present?
    conversation.update!(additional_attributes: attrs, last_activity_at: Time.current)
  end

  def sync_voice_message!(call_session)
    message = call_session.latest_voice_message
    return unless message

    data = (message.content_attributes || {}).deep_dup
    data['data'] ||= {}
    data['data']['status'] = call_session.status
    data['data']['recording_ref'] = call_session.recording_ref if call_session.recording_ref.present?
    data['data']['transcript_ref'] = call_session.transcript_ref if call_session.transcript_ref.present?
    transcript = payload_value('transcript')
    data['data']['transcript'] = transcript if transcript.present?
    data['data']['summary'] = call_session.summary if call_session.summary.present?
    data['data']['duration'] = call_session.duration_seconds if call_session.duration_seconds.present?
    message.update!(content_attributes: data)
  end

  def resolve_existing_conversation(account, call_session)
    return call_session.conversation if call_session.conversation.present?

    if (conversation_id = payload_value('conversation_id', 'conversationId')).present?
      conversation = account.conversations.find_by(id: conversation_id)
      return conversation if conversation.present?
    end

    if (conversation_id = metadata_value('chatwoot_conversation_id', 'conversation_id', 'conversationId')).present?
      conversation = account.conversations.find_by(id: conversation_id)
      return conversation if conversation.present?
    end

    if (display_id = payload_value('conversation_display_id', 'conversationDisplayId')).present?
      conversation = account.conversations.find_by(display_id: display_id)
      return conversation if conversation.present?
    end

    if (display_id = metadata_value('chatwoot_conversation_display_id', 'conversation_display_id', 'conversationDisplayId')).present?
      conversation = account.conversations.find_by(display_id: display_id)
      return conversation if conversation.present?
    end

    account.conversations.find_by(identifier: call_ref)
  end

  def resolve_contact(account, conversation)
    return conversation.contact if conversation&.contact.present?
    contact_id = payload_value('contact_id', 'contactId') || metadata_value('chatwoot_contact_id', 'contact_id', 'contactId')
    return account.contacts.find_by(id: contact_id) if contact_id.present?

    phone_number = caller_number if resolved_direction == 'inbound'
    phone_number ||= resolved_to_number if resolved_direction == 'outbound'
    return if phone_number.blank?

    account.contacts.find_by(phone_number: phone_number)
  end

  def resolve_inbox(account)
    inbox_id = payload_value('inbox_id', 'inboxId') || metadata_value('chatwoot_inbox_id', 'inbox_id', 'inboxId')
    return account.inboxes.find_by(id: inbox_id) if inbox_id.present?
    return resolve_number_binding&.inbox if resolve_number_binding.present?

    channel = Channel::Voice.find_by(phone_number: inbound_number)
    channel&.inbox
  end

  def resolve_number_binding
    @resolve_number_binding ||= begin
      if (number_ref = payload_value('number_ref', 'numberRef')).present?
        Telephony::NumberBinding.find_by(number_ref: number_ref)
      elsif inbound_number.present?
        Telephony::NumberBinding.find_by(phone_number: inbound_number)
      end
    end
  end

  def resolve_agent_binding(account)
    agent_ref = payload_value('agent_ref', 'agentRef') || metadata_value('agent_ref', 'agentRef')
    return account.telephony_agent_bindings.find_by(agent_ref: agent_ref) if agent_ref.present?

    metadata_user_id = metadata_value('chatwoot_user_id', 'user_id', 'userId')
    return if metadata_user_id.blank?

    account.telephony_agent_bindings.find_by(user_id: metadata_user_id)
  end

  def merged_metadata(call_session)
    base = (call_session.metadata || {}).deep_dup
    base['last_payload'] = payload
    base['metadata'] = metadata if metadata.present?
    base.compact
  end

  def find_or_create_event!(account)
    account.telephony_events.find_by(event_key: event_key) || begin
      event = account.telephony_events.new(
        event_key: event_key,
        event_type: resolved_event_type,
        payload: payload
      )
      event.save!
      event
    rescue ActiveRecord::RecordNotUnique
      account.telephony_events.find_by!(event_key: event_key)
    rescue ActiveRecord::RecordInvalid => e
      raise unless uniqueness_conflict?(e.record, :event_key)

      account.telephony_events.find_by!(event_key: event_key)
    end
  end

  def persist_call_session!(account, call_session)
    save_call_session!(call_session, yield(call_session))
  rescue ActiveRecord::RecordNotUnique
    existing_call_session = account.telephony_call_sessions.find_by!(external_call_ref: call_ref)
    save_call_session!(existing_call_session, yield(existing_call_session))
  rescue ActiveRecord::RecordInvalid => e
    raise unless uniqueness_conflict?(e.record, :external_call_ref)

    existing_call_session = account.telephony_call_sessions.find_by!(external_call_ref: call_ref)
    save_call_session!(existing_call_session, yield(existing_call_session))
  end

  def save_call_session!(call_session, attributes)
    call_session.assign_attributes(attributes)
    call_session.save!
    call_session
  end

  def uniqueness_conflict?(record, attribute)
    record&.errors&.of_kind?(attribute, :taken)
  end

  def event_key
    payload_value('event_key', 'eventKey', 'idempotency_key', 'idempotencyKey') ||
      Digest::SHA256.hexdigest(payload.except('controller', 'action').to_json)
  end

  def resolved_event_type
    payload_value('event', 'event_type', 'eventType', 'status') || 'unknown'
  end

  def call_ref
    payload_value('call_ref', 'callRef', 'call_sid', 'callSid', 'ref')
  end

  def resolved_status
    explicit = payload_value('status').to_s.strip.downcase
    return EVENT_STATUS_MAP[explicit] || explicit if explicit.present?

    event_name = payload_value('event', 'event_type', 'eventType').to_s.strip.downcase
    if event_name == 'dial_status'
      dial_status = nested_payload_value('status', 'callStatus').to_s.strip.downcase
      return EVENT_STATUS_MAP[dial_status] || dial_status if dial_status.present?
    end

    EVENT_STATUS_MAP[event_name]
  end

  def resolved_direction
    value = payload_value('direction').to_s.strip.downcase
    return 'inbound' if %w[inbound from_pstn].include?(value)
    return 'outbound' if %w[outbound outbound_api outbound-dial outbound_api_call].include?(value)

    value.presence_in(Telephony::CallSession::ALLOWED_DIRECTIONS)
  end

  def resolved_from_number
    payload_value('caller_number', 'callerNumber', 'from_number', 'fromNumber', 'from')
  end

  def resolved_to_number
    payload_value('callee_number', 'calleeNumber', 'to_number', 'toNumber', 'to') || inbound_number
  end

  def inbound_number
    payload_value('ingress_number', 'ingressNumber', 'to_number', 'toNumber', 'to')
  end

  def caller_number
    payload_value('caller_number', 'callerNumber', 'from_number', 'fromNumber', 'from')
  end

  def resolved_duration
    duration = payload_value('duration', 'call_duration', 'callDuration') || nested_payload_value('duration')
    duration&.to_i
  end

  def resolved_started_at
    parse_time(payload_value('started_at', 'startedAt')) ||
      parse_time(nested_payload_value('started_at', 'startedAt'))
  end

  def resolved_ended_at
    parse_time(payload_value('ended_at', 'endedAt')) ||
      parse_time(nested_payload_value('ended_at', 'endedAt'))
  end

  def resolved_occurred_at
    parse_time(payload_value('occurred_at', 'occurredAt')) ||
      parse_time(payload_value('received_at', 'receivedAt')) ||
      parse_time(payload_value('created_at', 'createdAt'))
  end

  def metadata
    value = payload['metadata'] || payload['payload']&.dig('metadata')
    return value if value.is_a?(Hash)

    {}
  end

  def metadata_value(*keys)
    keys.each do |key|
      value = metadata[key.to_s]
      return value if value.present?
    end

    nil
  end

  def resolve_metadata_conversation
    conversation_id = metadata_value('chatwoot_conversation_id', 'conversation_id', 'conversationId')
    return if conversation_id.blank?

    ::Conversation.find_by(id: conversation_id)
  end

  def resolve_metadata_inbox
    inbox_id = metadata_value('chatwoot_inbox_id', 'inbox_id', 'inboxId')
    return if inbox_id.blank?

    ::Inbox.find_by(id: inbox_id)
  end

  def resolve_metadata_contact
    contact_id = metadata_value('chatwoot_contact_id', 'contact_id', 'contactId')
    return if contact_id.blank?

    ::Contact.find_by(id: contact_id)
  end

  def payload_value(*keys)
    keys.each do |key|
      value = payload[key.to_s]
      return value if value.present?
    end

    nil
  end

  def nested_payload_value(*keys)
    nested = payload['payload']
    return nil unless nested.is_a?(Hash)

    keys.each do |key|
      value = nested[key.to_s]
      return value if value.present?
    end

    nil
  end

  def parse_time(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
