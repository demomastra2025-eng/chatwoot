class Contacts::ContactableInboxesService
  CONTACTABLE_INBOX_METHODS = {
    'Channel::TwilioSms' => :twilio_contactable_inbox,
    'Channel::Whatsapp' => :whatsapp_contactable_inbox,
    'Channel::WhatsappWeb' => :whatsapp_web_contactable_inbox,
    'Channel::Sms' => :sms_contactable_inbox,
    'Channel::TelegramPersonal' => :telegram_personal_contactable_inbox,
    'Channel::Telegram' => :telegram_contactable_inbox,
    'Channel::LinkedinPersonal' => :existing_source_contactable_inbox,
    'Channel::Weixin' => :existing_source_contactable_inbox,
    'Channel::VkCommunity' => :existing_source_contactable_inbox,
    'Channel::Line' => :existing_source_contactable_inbox,
    'Channel::FacebookPage' => :existing_source_contactable_inbox,
    'Channel::Instagram' => :existing_source_contactable_inbox,
    'Channel::Tiktok' => :existing_source_contactable_inbox,
    'Channel::TwitterProfile' => :twitter_contactable_inbox,
    'Channel::Email' => :email_contactable_inbox,
    'Channel::WebWidget' => :website_contactable_inbox
  }.freeze

  pattr_initialize [:contact!]

  def get
    account = contact.account
    account.inboxes.filter_map { |inbox| get_contactable_inbox(inbox) }
  end

  private

  def get_contactable_inbox(inbox)
    contactable_method = CONTACTABLE_INBOX_METHODS[inbox.channel_type]
    return __send__(contactable_method, inbox) if contactable_method

    api_contactable_inbox(inbox) if Inbox::API_CHANNEL_TYPES.include?(inbox.channel_type)
  end

  def website_contactable_inbox(inbox)
    latest_contact_inbox = inbox.contact_inboxes.where(contact: @contact).last
    return unless latest_contact_inbox
    # FIXME : change this when multiple conversations comes in
    return if latest_contact_inbox.conversations.present?

    { source_id: latest_contact_inbox.source_id, inbox: inbox }
  end

  def api_contactable_inbox(inbox)
    latest_contact_inbox = inbox.contact_inboxes.where(contact: @contact).last
    source_id = latest_contact_inbox&.source_id || SecureRandom.uuid

    { source_id: source_id, inbox: inbox }
  end

  def email_contactable_inbox(inbox)
    return if @contact.email.blank?

    { source_id: @contact.email, inbox: inbox }
  end

  def whatsapp_contactable_inbox(inbox)
    return if @contact.phone_number.blank?

    # Remove the plus since thats the format 360 dialog uses
    { source_id: @contact.phone_number.delete('+'), inbox: inbox }
  end

  def whatsapp_web_contactable_inbox(inbox)
    return if @contact.phone_number.blank?

    latest_contact_inbox = inbox.contact_inboxes.where(contact: @contact).last
    source_id = latest_contact_inbox&.source_id.presence || @contact.phone_number.delete('+')

    { source_id: source_id, inbox: inbox }
  end

  def sms_contactable_inbox(inbox)
    return if @contact.phone_number.blank?

    { source_id: @contact.phone_number, inbox: inbox }
  end

  def telegram_personal_contactable_inbox(inbox)
    source_id = @contact.additional_attributes['social_telegram_user_id'] || inbox.contact_inboxes.where(contact: @contact).last&.source_id
    return if source_id.blank?

    { source_id: source_id.to_s, inbox: inbox }
  end

  def telegram_contactable_inbox(inbox)
    source_id = @contact.additional_attributes['social_telegram_user_id'] || inbox.contact_inboxes.where(contact: @contact).last&.source_id
    return if source_id.blank?

    { source_id: source_id.to_s, inbox: inbox }
  end

  def existing_source_contactable_inbox(inbox)
    source_id = inbox.contact_inboxes.where(contact: @contact).last&.source_id
    return if source_id.blank?

    { source_id: source_id.to_s, inbox: inbox }
  end

  def twitter_contactable_inbox(inbox)
    source_id = inbox.contact_inboxes.where(contact: @contact).last&.source_id
    return if source_id.blank?
    return unless inbox.conversations.where(contact: @contact).exists?(
      ["additional_attributes ->> 'type' = ?", 'direct_message']
    )

    { source_id: source_id.to_s, inbox: inbox }
  end

  def twilio_contactable_inbox(inbox)
    return if @contact.phone_number.blank?

    case inbox.channel.medium
    when 'sms'
      { source_id: @contact.phone_number, inbox: inbox }
    when 'whatsapp'
      { source_id: "whatsapp:#{@contact.phone_number}", inbox: inbox }
    end
  end
end

Contacts::ContactableInboxesService.prepend_mod_with('Contacts::ContactableInboxesService')
