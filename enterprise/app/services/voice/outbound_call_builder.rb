require 'digest'

class Voice::OutboundCallBuilder
  PROVIDER_OWNED_SIP_PROVIDERS = %w[asterisk_analog sipuni binotel].freeze

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
    raise ArgumentError, 'Contact must belong to account' if contact.account_id != account.id
    raise ArgumentError, 'Inbox must belong to account' if inbox.account_id != account.id

    timestamp = current_timestamp

    ActiveRecord::Base.transaction do
      lock_call_identity!
      contact_inbox = ensure_contact_inbox!
      @contact = contact_inbox.contact
      raise ArgumentError, 'Contact inbox must belong to account' if contact.account_id != account.id

      conversation = find_or_create_conversation!(contact_inbox)
      conversation.reload
      validate_conversation!(conversation, contact_inbox)
      conference_sid = Voice::Conference::Name.for(conversation)
      call = initiate_call!(conversation)
      call_sid = call[:call_sid]
      status = call[:status] || 'ringing'
      update_conversation!(conversation, call_sid, conference_sid, timestamp, status)
      build_voice_message!(conversation, call_sid, conference_sid, timestamp, status)
      { conversation: conversation, call_sid: call_sid, call_session: call[:call_session], browser_join_supported: call[:browser_join_supported] }
    end
  end

  private

  def ensure_contact_inbox!
    ContactInbox.find_by(inbox_id: inbox.id, source_id: normalized_contact_phone) ||
      ContactInbox.create_or_find_by!(inbox_id: inbox.id, source_id: normalized_contact_phone) do |record|
        record.contact = contact
      end
  end

  def lock_call_identity!
    identity = ['voice-contact', account.id, normalized_contact_phone].join(':')
    lock_id = Digest::SHA256.digest(identity).unpack1('q>')
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{lock_id})")
  end

  def validate_conversation!(conversation, contact_inbox)
    valid = conversation.account_id == account.id &&
            conversation.inbox_id == inbox.id &&
            conversation.contact_id == contact.id &&
            conversation.contact_inbox_id == contact_inbox.id
    return if valid

    raise ArgumentError, 'conversation does not match voice context'
  end

  def normalized_contact_phone
    @normalized_contact_phone ||= Contacts::PhoneNumberNormalizer.normalize(contact.phone_number) ||
                                  Contacts::PhoneNumberNormalizer.normalize(contact.phone_number, default_country: 'KZ') ||
                                  contact.phone_number
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
    reusable_native_telephony_conversation || create_conversation!(contact_inbox)
  end

  def reusable_native_telephony_conversation
    return unless native_telephony_provider?

    account.conversations
           .where(inbox_id: inbox.id, contact_id: contact.id)
           .order(last_activity_at: :desc, id: :desc)
           .first
  end

  def provider_owned_sip_provider?
    inbox.channel.provider.to_s.in?(PROVIDER_OWNED_SIP_PROVIDERS)
  end

  def native_telephony_provider?
    provider_owned_sip_provider?
  end

  def initiate_call!(conversation)
    if native_telephony_provider?
      result = Telephony::CallsService.new(account: account).create_outbound!(
        inbox: inbox,
        contact: contact,
        user: user,
        conversation: conversation
      )

      {
        call_sid: result[:call_ref],
        status: result[:status],
        call_session: result[:call_session],
        browser_join_supported: result[:browser_join_supported]
      }
    else
      result = inbox.channel.initiate_call(to: contact.phone_number)
      {
        call_sid: result[:call_sid],
        status: result[:status],
        call_session: nil
      }.compact
    end
  end

  def update_conversation!(conversation, call_sid, conference_sid, timestamp, status)
    attrs = (conversation.additional_attributes || {}).deep_dup
    reset_reused_native_call_state!(attrs, call_sid)
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
    attrs['telephony_call_ref'] = call_sid if native_telephony_provider?

    update_attrs = {
      additional_attributes: attrs,
      last_activity_at: current_time
    }
    update_attrs[:identifier] = call_sid unless native_telephony_provider? && conversation.identifier.present?
    update_attrs[:status] = :open if native_telephony_provider?

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

  def reset_reused_native_call_state!(attrs, call_sid)
    return unless native_telephony_provider?

    return if current_call_ref(attrs) == call_sid

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
