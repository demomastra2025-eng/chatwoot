class Contacts::ContactableInboxesService
  pattr_initialize [:contact!]

  def get
    account = contact.account
    account.inboxes.filter_map { |inbox| get_contactable_inbox(inbox) }
  end

  private

  def get_contactable_inbox(inbox)
    case inbox.channel_type
    when 'Channel::TwilioSms'
      twilio_contactable_inbox(inbox)
    when 'Channel::Whatsapp'
      whatsapp_contactable_inbox(inbox)
    when 'Channel::WhatsappWeb'
      whatsapp_web_contactable_inbox(inbox)
    when 'Channel::Sms'
      sms_contactable_inbox(inbox)
    when 'Channel::TelegramPersonal'
      telegram_personal_contactable_inbox(inbox)
    when 'Channel::Telegram'
      telegram_contactable_inbox(inbox)
    when 'Channel::VkCommunity'
      vk_community_contactable_inbox(inbox)
    when 'Channel::Line'
      line_contactable_inbox(inbox)
    when 'Channel::FacebookPage'
      facebook_contactable_inbox(inbox)
    when 'Channel::Instagram'
      instagram_contactable_inbox(inbox)
    when 'Channel::Tiktok'
      tiktok_contactable_inbox(inbox)
    when 'Channel::TwitterProfile'
      twitter_contactable_inbox(inbox)
    when 'Channel::Email'
      email_contactable_inbox(inbox)
    when *Inbox::API_CHANNEL_TYPES
      api_contactable_inbox(inbox)
    when 'Channel::WebWidget'
      website_contactable_inbox(inbox)
    end
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

  def vk_community_contactable_inbox(inbox)
    source_id = inbox.contact_inboxes.where(contact: @contact).last&.source_id
    return if source_id.blank?

    { source_id: source_id.to_s, inbox: inbox }
  end

  def line_contactable_inbox(inbox)
    source_id = inbox.contact_inboxes.where(contact: @contact).last&.source_id
    return if source_id.blank?

    { source_id: source_id.to_s, inbox: inbox }
  end

  def facebook_contactable_inbox(inbox)
    source_id = inbox.contact_inboxes.where(contact: @contact).last&.source_id
    return if source_id.blank?

    { source_id: source_id.to_s, inbox: inbox }
  end

  def instagram_contactable_inbox(inbox)
    source_id = inbox.contact_inboxes.where(contact: @contact).last&.source_id
    return if source_id.blank?

    { source_id: source_id.to_s, inbox: inbox }
  end

  def tiktok_contactable_inbox(inbox)
    source_id = inbox.contact_inboxes.where(contact: @contact).last&.source_id
    return if source_id.blank?

    { source_id: source_id.to_s, inbox: inbox }
  end

  def twitter_contactable_inbox(inbox)
    source_id = inbox.contact_inboxes.where(contact: @contact).last&.source_id
    return if source_id.blank?
    return unless inbox.conversations.where(contact: @contact).where("additional_attributes ->> 'type' = ?", 'direct_message').exists?

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
