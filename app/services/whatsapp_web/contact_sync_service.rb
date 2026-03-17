class WhatsappWeb::ContactSyncService
  pattr_initialize [:channel!, :contact_payload!]

  def perform
    return if canonical_remote_jid.blank?
    return unless supported_personal_remote_jid?
    return if ignored_remote_jid?
    return if source_id.blank?

    contact_inbox = ContactInboxWithContactBuilder.new(
      inbox: channel.inbox,
      source_id: source_id,
      contact_attributes: create_contact_attributes,
      skip_runtime_events: true
    ).perform

    sync_existing_contact(contact_inbox.contact)
    sync_avatar(contact_inbox.contact)
    contact_inbox
  end

  private

  def raw_remote_jid
    @raw_remote_jid ||= contact_payload[:remoteJid].to_s.presence
  end

  def canonical_remote_jid
    @canonical_remote_jid ||= WhatsappWeb::ProviderPayloadNormalizer.canonical_remote_jid(
      contact_payload[:canonicalJid],
      raw_remote_jid,
      contact_payload[:remoteJidAlt],
      contact_payload[:remoteLid]
    )
  end

  def source_id
    @source_id ||= begin
      candidate = canonical_remote_jid.to_s.split('@').first.to_s.gsub(/\D/, '')
      candidate.presence if candidate.present? && candidate != '0'
    end
  end

  def phone_number
    source_id.present? ? "+#{source_id}" : nil
  end

  def display_name
    value = preferred_display_name || phone_number
    value.to_s.truncate(100)
  end

  def profile_pic_url
    contact_payload[:profilePicUrl].presence
  end

  def create_contact_attributes
    {
      name: display_name,
      phone_number: phone_number,
      additional_attributes: additional_attributes,
      avatar_url: profile_pic_url
    }.compact
  end

  def additional_attributes
    {
      raw_jid: raw_remote_jid,
      canonical_jid: canonical_remote_jid,
      provider: 'whatsapp_web',
      profile_pic_url: profile_pic_url
    }.compact
  end

  def sync_existing_contact(contact)
    updates = {}
    current_attributes = (contact.additional_attributes || {}).deep_stringify_keys
    merged_attributes = current_attributes.merge(additional_attributes.deep_stringify_keys)

    updates[:additional_attributes] = merged_attributes if merged_attributes != current_attributes
    updates[:phone_number] = phone_number if contact.phone_number.blank? && phone_number.present?

    if should_replace_contact_name?(contact)
      updates[:name] = display_name
    end

    return if updates.blank?

    contact.skip_runtime_events = true
    contact.update!(updates)
  end

  def sync_avatar(contact)
    return if profile_pic_url.blank?

    Avatar::AvatarFromUrlJob.perform_later(contact, profile_pic_url)
  end

  def preferred_display_name
    [contact_payload[:pushName], contact_payload[:name]].find do |value|
      value.present? && !placeholder_display_name?(value)
    end
  end

  def placeholder_display_name?(value)
    normalized = I18n.transliterate(value.to_s).strip.downcase
    normalized.blank? || %w[voce you].include?(normalized)
  end

  def should_replace_contact_name?(contact)
    return false if display_name.blank?
    return true if contact.name.blank?
    return true if placeholder_display_name?(contact.name)
    return true if contact.name == contact.phone_number
    return true if phone_number.present? && contact.name == phone_number

    normalized_name = contact.name.to_s.gsub(/\D/, '')
    normalized_phone = phone_number.to_s.gsub(/\D/, '')
    normalized_name == normalized_phone
  end

  def ignored_remote_jid?
    [raw_remote_jid, canonical_remote_jid].compact.any? { |jid| channel.ignored_remote_jid?(jid) }
  end

  def supported_personal_remote_jid?
    canonical_remote_jid.end_with?('@s.whatsapp.net')
  end
end
