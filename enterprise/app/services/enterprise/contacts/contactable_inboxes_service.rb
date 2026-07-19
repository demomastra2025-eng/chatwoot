module Enterprise::Contacts::ContactableInboxesService
  private

  # Extend base selection to include Voice inboxes
  def get_contactable_inbox(inbox)
    return voice_contactable_inbox(inbox) if inbox.channel_type == 'Channel::Voice'

    super
  end

  def voice_contactable_inbox(inbox)
    phone_number = contact_phone_number
    return if phone_number.blank?

    { source_id: phone_number, inbox: inbox }
  end
end
