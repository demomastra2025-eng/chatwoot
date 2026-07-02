class Voice::InboundCallBuilder
  PROVIDER_OWNED_SIP_PROVIDERS = Channel::Voice::PROVIDER_OWNED_SIP_PROVIDERS

  attr_reader :account, :inbox, :from_number, :call_sid

  def self.perform!(account:, inbox:, from_number:, call_sid:)
    new(account: account, inbox: inbox, from_number: from_number, call_sid: call_sid).perform!
  end

  def initialize(account:, inbox:, from_number:, call_sid:)
    @account = account
    @inbox = inbox
    @from_number = from_number
    @call_sid = call_sid
  end

  def perform!
    timestamp = current_timestamp

    ActiveRecord::Base.transaction do
      contact = ensure_contact!
      contact_inbox = ensure_contact_inbox!(contact)
      conversation = find_conversation(contact) || create_conversation!(contact, contact_inbox)
      conversation.reload
      update_conversation!(conversation, timestamp)
      build_voice_message!(conversation, timestamp)
      conversation
    end
  end

  private

  def ensure_contact!
    account.contacts.find_or_create_by!(phone_number: normalized_from_number) do |record|
      record.name = normalized_from_number if record.name.blank?
    end
  end

  def ensure_contact_inbox!(contact)
    ContactInbox.find_or_create_by!(
      contact_id: contact.id,
      inbox_id: inbox.id
    ) do |record|
      record.source_id = normalized_from_number
    end
  end

  def find_conversation(contact)
    conversation = account.conversations.includes(:contact).find_by(identifier: call_sid) if call_sid.present?
    return conversation if conversation.present?

    reusable_native_telephony_conversation(contact)
  end

  def reusable_native_telephony_conversation(contact)
    return unless native_telephony_provider?

    account.conversations
           .where(inbox_id: inbox.id, contact_id: contact.id)
           .order(last_activity_at: :desc, id: :desc)
           .first
  end

  def create_conversation!(contact, contact_inbox)
    attrs = {
      contact_inbox_id: contact_inbox.id,
      inbox_id: inbox.id,
      contact_id: contact.id,
      status: :open
    }
    attrs[:identifier] = call_sid unless native_telephony_provider?

    account.conversations.create!(attrs)
  end

  def update_conversation!(conversation, timestamp)
    attrs = (conversation.additional_attributes || {}).deep_dup
    reset_reused_call_state!(attrs)
    attrs.merge!(
      'call_direction' => 'inbound',
      'call_status' => 'ringing',
      'conference_sid' => Voice::Conference::Name.for(conversation),
      'from_number' => normalized_from_number,
      'to_number' => inbox.channel&.phone_number
    )
    attrs['meta'] = attrs['meta'].is_a?(Hash) ? attrs['meta'] : {}
    attrs['meta']['initiated_at'] = timestamp
    attrs[provider_call_ref_key] = call_sid if native_telephony_provider?

    update_attrs = {
      additional_attributes: attrs,
      last_activity_at: current_time
    }
    update_attrs[:identifier] = call_sid unless native_telephony_provider? && conversation.identifier.present?
    update_attrs[:status] = :open if native_telephony_provider?

    conversation.update!(update_attrs)
  end

  def build_voice_message!(conversation, timestamp)
    Voice::CallMessageBuilder.perform!(
      conversation: conversation,
      direction: 'inbound',
      payload: {
        call_sid: call_sid,
        status: 'ringing',
        conference_sid: conversation.additional_attributes['conference_sid'],
        from_number: normalized_from_number,
        to_number: inbox.channel&.phone_number
      },
      timestamps: { created_at: timestamp, ringing_at: timestamp }
    )
  end

  def normalized_from_number
    @normalized_from_number ||= Contacts::PhoneNumberNormalizer.normalize(from_number) ||
                                Contacts::PhoneNumberNormalizer.normalize(from_number, default_country: 'KZ') ||
                                from_number
  end

  def current_timestamp
    @current_timestamp ||= current_time.to_i
  end

  def current_time
    @current_time ||= Time.zone.now
  end

  def fonoster_provider?
    inbox.channel&.provider == 'fonoster'
  end

  def provider_owned_sip_provider?
    inbox.channel&.provider.to_s.in?(PROVIDER_OWNED_SIP_PROVIDERS)
  end

  def native_telephony_provider?
    fonoster_provider? || provider_owned_sip_provider?
  end

  def reset_reused_call_state!(attrs)
    return unless native_telephony_provider?

    call_ref_key = provider_call_ref_key
    return if attrs[call_ref_key].present? && attrs[call_ref_key] == call_sid

    %w[
      agent_id
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

  def provider_call_ref_key
    return 'fonoster_call_ref' if fonoster_provider?

    "#{inbox.channel.provider}_call_ref"
  end
end
