class WhatsappWeb::MarkMessagesReadService
  pattr_initialize [:conversation!, { messages: nil }]

  def perform
    return false unless channel.is_a?(Channel::WhatsappWeb)

    read_messages = provider_read_messages
    return false if read_messages.blank?

    channel.provider_service.mark_messages_read(messages: read_messages)
    true
  rescue StandardError => e
    Rails.logger.warn(
      "[WHATSAPP WEB] Failed to mark messages read for conversation=#{conversation.id} channel=#{channel.id}: #{e.class}: #{e.message}"
    )
    false
  end

  private

  delegate :inbox, :contact_inbox, :contact, to: :conversation

  def channel
    inbox.channel
  end

  def provider_read_messages
    remote_jid = conversation_remote_jid
    return [] if remote_jid.blank?

    unread_messages.filter_map do |message|
      source_id = message.source_id.to_s.presence
      next if source_id.blank?

      {
        remoteJid: remote_jid,
        fromMe: false,
        id: source_id
      }
    end.uniq { |message| message[:id] }
  end

  def unread_messages
    Array.wrap(messages).presence || conversation.unread_messages.where(account_id: conversation.account_id).incoming.to_a
  end

  def conversation_remote_jid
    contact_attributes = (contact.additional_attributes || {}).with_indifferent_access
    whatsapp_profile = whatsapp_channel_profile(contact_attributes)
    source_id = contact_inbox&.source_id.to_s.strip

    [
      whatsapp_profile&.[](:canonical_jid),
      whatsapp_profile&.[](:raw_jid),
      contact_attributes[:canonical_jid],
      contact_attributes[:raw_jid],
      source_id.presence&.then { |value| value.include?('@') ? value : "#{value.gsub(/\D/, '')}@s.whatsapp.net" }
    ].find(&:present?)
  end

  def whatsapp_channel_profile(contact_attributes)
    profiles = contact_attributes[:channel_profiles].to_h.with_indifferent_access[:whatsapp_web].to_h.with_indifferent_access
    source_id = contact_inbox&.source_id.to_s.strip
    identifier = contact.identifier.to_s.strip

    profiles.values.find do |profile|
      attributes = profile.to_h.with_indifferent_access
      [
        attributes[:source_id].to_s.strip,
        attributes[:identifier].to_s.strip,
        attributes[:canonical_jid].to_s.strip,
        attributes[:raw_jid].to_s.strip,
        attributes[:lid_jid].to_s.strip
      ].any?(&:present?) && [
        attributes[:source_id].to_s.strip,
        attributes[:identifier].to_s.strip,
        attributes[:canonical_jid].to_s.strip,
        attributes[:raw_jid].to_s.strip,
        attributes[:lid_jid].to_s.strip
      ].include?(source_id.presence || identifier)
    end || profiles.values.first&.with_indifferent_access
  end
end
