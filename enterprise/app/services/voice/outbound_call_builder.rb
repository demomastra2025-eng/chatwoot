class Voice::OutboundCallBuilder
  attr_reader :account, :inbox, :user, :contact

  def self.perform!(account:, inbox:, user:, contact:)
    new(account: account, inbox: inbox, user: user, contact: contact).perform!
  end

  def initialize(account:, inbox:, user:, contact:)
    @account = account
    @inbox = inbox
    @user = user
    @contact = contact
  end

  def perform!
    raise ArgumentError, 'Contact phone number required' if contact.phone_number.blank?
    raise ArgumentError, 'Agent required' if user.blank?

    timestamp = current_timestamp
    return perform_sipuni_outbound!(timestamp) if sipuni_provider?

    ActiveRecord::Base.transaction do
      contact_inbox = ensure_contact_inbox!
      conversation = find_or_create_conversation!(contact_inbox)
      conversation.reload
      conference_sid = Voice::Conference::Name.for(conversation)
      call = initiate_call!(conversation)
      call_sid = call[:call_sid]
      status = call[:status] || 'ringing'
      update_conversation!(conversation, call_sid, conference_sid, timestamp, status)
      build_voice_message!(conversation, call_sid, conference_sid, timestamp, status)
      { conversation: conversation, call_sid: call_sid, call_session: call[:call_session] }
    end
  end

  private

  def ensure_contact_inbox!
    ContactInbox.find_or_create_by!(
      contact_id: contact.id,
      inbox_id: inbox.id
    ) do |record|
      record.source_id = contact.phone_number
    end
  end

  def create_conversation!(contact_inbox)
    account.conversations.create!(
      contact_inbox_id: contact_inbox.id,
      inbox_id: inbox.id,
      contact_id: contact.id,
      status: :open
    )
  end

  def find_or_create_conversation!(contact_inbox)
    reusable_fonoster_conversation || create_conversation!(contact_inbox)
  end

  def reusable_fonoster_conversation
    return unless fonoster_provider?

    account.conversations
           .where(inbox_id: inbox.id, contact_id: contact.id)
           .order(last_activity_at: :desc, id: :desc)
           .first
  end

  def perform_sipuni_outbound!(timestamp)
    conversation = nil
    conference_sid = nil

    ActiveRecord::Base.transaction do
      contact_inbox = ensure_contact_inbox!
      conversation = create_conversation!(contact_inbox)
      conversation.reload
      conference_sid = Voice::Conference::Name.for(conversation)
      mark_sipuni_pending_conversation!(conversation, conference_sid, timestamp)
    end

    call = nil
    begin
      call = initiate_call!(conversation)
    rescue StandardError
      cleanup_failed_sipuni_pending_conversation!(conversation)
      raise
    end
    call_session = finalize_sipuni_initiation!(conversation, call, conference_sid, timestamp)
    provider_request_ref = sipuni_provider_request_ref(call)

    {
      conversation: conversation.reload,
      call_sid: call_session&.external_call_ref || provider_request_ref,
      provider_request_ref: provider_request_ref,
      call_session: call_session
    }
  end

  def mark_sipuni_pending_conversation!(conversation, conference_sid, timestamp)
    conversation.update!(
      additional_attributes: sipuni_conversation_attributes(
        conversation: conversation,
        conference_sid: conference_sid,
        timestamp: timestamp,
        status: 'created',
        provider_request_ref: nil,
        call: nil,
        pending: true
      ),
      last_activity_at: current_time
    )
  end

  def cleanup_failed_sipuni_pending_conversation!(conversation)
    conversation.reload
    return if sipuni_call_session_for(conversation).present?
    return if conversation.messages.exists?

    conversation.destroy!
  end

  def finalize_sipuni_initiation!(conversation, call, conference_sid, timestamp)
    conversation.reload
    call_session = sipuni_call_session_for(conversation)
    provider_request_ref = sipuni_provider_request_ref(call)
    status = call_session&.status || call[:status] || 'ringing'
    update_attrs = {
      additional_attributes: sipuni_conversation_attributes(
        conversation: conversation,
        conference_sid: conference_sid,
        timestamp: timestamp,
        status: status,
        provider_request_ref: provider_request_ref,
        call: call,
        pending: call_session.blank?
      ),
      last_activity_at: current_time
    }
    update_attrs[:identifier] = call_session.external_call_ref if call_session.present?
    conversation.update!(update_attrs)

    if call_session.present?
      update_sipuni_call_session_initiation_metadata!(call_session, call)
    else
      build_sipuni_pending_voice_message!(conversation, provider_request_ref, conference_sid, timestamp, status)
    end

    call_session
  end

  def sipuni_conversation_attributes(conversation:, conference_sid:, timestamp:, status:, provider_request_ref:, call:, pending:)
    attrs = (conversation.additional_attributes || {}).deep_dup
    attrs['call_direction'] = 'outbound'
    attrs['call_status'] = next_sipuni_conversation_status(attrs['call_status'], status)
    attrs['agent_id'] = user.id
    attrs['conference_sid'] = conference_sid
    attrs['telephony_provider'] = 'sipuni'
    attrs['from_number'] = inbox.channel&.phone_number
    attrs['to_number'] = contact.phone_number
    attrs['meta'] = sipuni_conversation_meta(attrs['meta'], timestamp, provider_request_ref, call, pending)
    attrs.compact
  end

  def sipuni_conversation_meta(existing_meta, timestamp, provider_request_ref, call, pending)
    meta = existing_meta.is_a?(Hash) ? existing_meta.deep_dup : {}
    meta['initiated_at'] ||= timestamp
    meta['provider_request_ref'] = provider_request_ref if provider_request_ref.present?
    meta['provider_request_status'] = call[:status] if call&.dig(:status).present?
    meta['sipuni_callback_response'] = call[:sipuni_response] if call&.dig(:sipuni_response).present?
    meta['provider_request_pending'] = pending
    meta.compact
  end

  def next_sipuni_conversation_status(current_status, next_status)
    current = Telephony::CallSession.normalize_status(current_status)
    normalized_next = Telephony::CallSession.normalize_status(next_status) || next_status
    return current if current.in?(Telephony::CallSession::TERMINAL_STATUSES) && !normalized_next.in?(Telephony::CallSession::TERMINAL_STATUSES)

    normalized_next.presence || current || 'ringing'
  end

  def build_sipuni_pending_voice_message!(conversation, provider_request_ref, conference_sid, timestamp, status)
    return if sipuni_call_session_for(conversation).present?

    Voice::CallMessageBuilder.perform!(
      conversation: conversation,
      direction: 'outbound',
      payload: {
        call_sid: nil,
        provider_request_ref: provider_request_ref,
        status: status,
        conference_sid: conference_sid,
        from_number: inbox.channel&.phone_number,
        to_number: contact.phone_number
      },
      user: user,
      timestamps: { created_at: timestamp, ringing_at: timestamp }
    )
  end

  def sipuni_call_session_for(conversation)
    account.telephony_call_sessions
           .where(conversation_id: conversation.id, provider: 'sipuni', direction: 'outbound')
           .order(created_at: :desc, id: :desc)
           .first
  end

  def update_sipuni_call_session_initiation_metadata!(call_session, call)
    initiation_metadata = sipuni_initiation_metadata(call)
    return if initiation_metadata.blank?

    metadata = (call_session.metadata || {}).deep_dup
    existing = metadata['sipuni_outbound_initiation'].is_a?(Hash) ? metadata['sipuni_outbound_initiation'].deep_dup : {}
    metadata['sipuni_outbound_initiation'] = existing.merge(initiation_metadata)
    call_session.update!(metadata: metadata.compact)
  end

  def sipuni_initiation_metadata(call)
    {
      'provider_request_ref' => sipuni_provider_request_ref(call),
      'provider_request_status' => call[:status],
      'sipuni_callback_response' => call[:sipuni_response]
    }.compact
  end

  def sipuni_provider_request_ref(call)
    call[:provider_request_ref].presence || call[:callback_id].presence || call[:call_sid].presence
  end

  def sipuni_provider?
    inbox.channel.provider == 'sipuni'
  end

  def fonoster_provider?
    inbox.channel.provider == 'fonoster'
  end

  def initiate_call!(conversation)
    if fonoster_provider?
      result = Telephony::CallsService.new(account: account).create_outbound!(
        inbox: inbox,
        contact: contact,
        user: user,
        conversation: conversation
      )

      {
        call_sid: result[:call_ref],
        status: result[:status],
        call_session: result[:call_session]
      }
    else
      result = inbox.channel.initiate_call(to: contact.phone_number)
      {
        call_sid: result[:call_sid],
        provider_request_ref: result[:provider_request_ref],
        status: result[:status],
        sipuni_response: result[:sipuni_response],
        call_session: nil
      }.compact
    end
  end

  def update_conversation!(conversation, call_sid, conference_sid, timestamp, status)
    attrs = (conversation.additional_attributes || {}).deep_dup
    reset_reused_fonoster_call_state!(attrs, call_sid)
    attrs.merge!(
      'call_direction' => 'outbound',
      'call_status' => status,
      'agent_id' => user.id,
      'conference_sid' => conference_sid,
      'telephony_provider' => inbox.channel.provider,
      'from_number' => inbox.channel&.phone_number,
      'to_number' => contact.phone_number
    )
    attrs['meta'] = attrs['meta'].is_a?(Hash) ? attrs['meta'] : {}
    attrs['meta']['initiated_at'] = timestamp
    attrs['fonoster_call_ref'] = call_sid if fonoster_provider?

    update_attrs = {
      additional_attributes: attrs,
      last_activity_at: current_time
    }
    update_attrs[:identifier] = call_sid unless fonoster_provider?
    update_attrs[:status] = :open if fonoster_provider?

    conversation.update!(update_attrs)
  end

  def build_voice_message!(conversation, call_sid, conference_sid, timestamp, status)
    Voice::CallMessageBuilder.perform!(
      conversation: conversation,
      direction: 'outbound',
      payload: {
        call_sid: call_sid,
        status: status,
        conference_sid: conference_sid,
        from_number: inbox.channel&.phone_number,
        to_number: contact.phone_number
      },
      user: user,
      timestamps: { created_at: timestamp, ringing_at: timestamp }
    )
  end

  def current_timestamp
    @current_timestamp ||= current_time.to_i
  end

  def current_time
    @current_time ||= Time.zone.now
  end

  def reset_reused_fonoster_call_state!(attrs, call_sid)
    return unless fonoster_provider?
    return if attrs['fonoster_call_ref'].present? && attrs['fonoster_call_ref'] == call_sid

    %w[
      call_started_at
      call_ended_at
      call_duration
      recording_ref
      recording
      transcript_ref
      summary
      from_number
      to_number
    ].each { |key| attrs.delete(key) }
  end
end
