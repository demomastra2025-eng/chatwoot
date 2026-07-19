require 'digest'

class Voice::InboundCallBuilder
  PROVIDER_OWNED_SIP_PROVIDERS = Channel::Voice::PROVIDER_OWNED_SIP_PROVIDERS

  attr_reader :account, :inbox, :from_number, :call_sid, :reuse_existing_conversation, :excluded_conversation_id,
              :conversation_identifier, :build_voice_message

  def self.perform!(account:, inbox:, from_number:, call_sid:, reuse_existing_conversation: true, excluded_conversation_id: nil,
                    conversation_identifier: nil, build_voice_message: true)
    new(
      account: account,
      inbox: inbox,
      from_number: from_number,
      call_sid: call_sid,
      reuse_existing_conversation: reuse_existing_conversation,
      excluded_conversation_id: excluded_conversation_id,
      conversation_identifier: conversation_identifier,
      build_voice_message: build_voice_message
    ).perform!
  end

  def initialize(account:, inbox:, from_number:, call_sid:, reuse_existing_conversation: true, excluded_conversation_id: nil,
                 conversation_identifier: nil, build_voice_message: true)
    @account = account
    @inbox = inbox
    @from_number = from_number
    @call_sid = call_sid
    @reuse_existing_conversation = reuse_existing_conversation
    @excluded_conversation_id = excluded_conversation_id
    @conversation_identifier = conversation_identifier
    @build_voice_message = build_voice_message
  end

  def perform!
    raise ArgumentError, 'inbox must belong to account' unless inbox.account_id == account.id

    timestamp = current_timestamp

    ActiveRecord::Base.transaction do
      lock_call_identity!
      contact = ensure_contact!
      contact_inbox = ensure_contact_inbox!(contact)
      contact = contact_inbox.contact
      raise ArgumentError, 'contact inbox must belong to account' unless contact.account_id == account.id

      conversation = find_conversation(contact) || create_conversation!(contact, contact_inbox)
      conversation.reload
      validate_conversation!(conversation, contact, contact_inbox)
      update_conversation!(conversation, timestamp, contact_inbox)
      build_voice_message!(conversation, timestamp) if build_voice_message
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
    ContactInbox.find_by(inbox_id: inbox.id, source_id: normalized_from_number) ||
      ContactInbox.create_or_find_by!(inbox_id: inbox.id, source_id: normalized_from_number) do |record|
        record.contact = contact
      end
  end

  def lock_call_identity!
    identity = ['voice-contact', account.id, normalized_from_number].join(':')
    lock_id = Digest::SHA256.digest(identity).unpack1('q>')
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{lock_id})")
  end

  def validate_conversation!(conversation, contact, contact_inbox)
    valid = conversation.account_id == account.id &&
            conversation.inbox_id == inbox.id &&
            conversation.contact_id == contact.id &&
            (conversation.contact_inbox_id.blank? || conversation.contact_inbox_id == contact_inbox.id)
    return if valid

    raise ArgumentError, 'conversation does not match voice context'
  end

  def find_conversation(contact)
    conversations = account.conversations.includes(:contact).where.not(id: excluded_conversation_id)
    identifier = conversation_identifier || call_sid
    conversation = conversations.find_by(identifier: identifier) if identifier.present?
    return conversation if conversation.present?
    return unless reuse_existing_conversation

    reusable_native_telephony_conversation(contact)
  end

  def reusable_native_telephony_conversation(contact)
    return unless native_telephony_provider?

    account.conversations
           .where.not(id: excluded_conversation_id)
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
    attrs[:identifier] = conversation_identifier || call_sid unless native_telephony_provider? && reuse_existing_conversation

    account.conversations.create!(attrs)
  end

  def update_conversation!(conversation, timestamp, contact_inbox)
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
    attrs['telephony_call_ref'] = call_sid if native_telephony_provider?

    update_attrs = {
      additional_attributes: attrs,
      last_activity_at: current_time
    }
    update_attrs[:contact_inbox] = contact_inbox if conversation.contact_inbox_id.blank?
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

  def provider_owned_sip_provider?
    inbox.channel&.provider.to_s.in?(PROVIDER_OWNED_SIP_PROVIDERS)
  end

  def native_telephony_provider?
    provider_owned_sip_provider?
  end

  def reset_reused_call_state!(attrs)
    return unless native_telephony_provider?

    return if current_call_ref(attrs) == call_sid

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
      telephony_call_ref
      sipuni_call_ref
      binotel_call_ref
      asterisk_analog_call_ref
      fonoster_call_ref
    ].each { |key| attrs.delete(key) }
  end

  def current_call_ref(attrs)
    attrs['telephony_call_ref'].presence ||
      attrs['sipuni_call_ref'].presence ||
      attrs['binotel_call_ref'].presence ||
      attrs['asterisk_analog_call_ref'].presence ||
      attrs['fonoster_call_ref'].presence
  end
end
