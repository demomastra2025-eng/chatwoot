class WhatsappWeb::ContactSyncService
  pattr_initialize [:channel!, :contact_payload!]

  def perform
    return if canonical_remote_jid.blank?
    return unless supported_personal_remote_jid?
    return if ignored_remote_jid?
    return if source_id.blank?

    contact_inbox = find_or_create_contact_inbox
    return if contact_inbox.blank?

    sync_existing_contact(contact_inbox.contact)
    sync_avatar(contact_inbox.contact)
    contact_inbox
  end

  private

  def raw_remote_jid
    @raw_remote_jid ||= contact_payload[:remoteJid].to_s.presence
  end

  def find_or_create_contact_inbox
    ContactInboxWithContactBuilder.new(
      inbox: channel.inbox,
      source_id: source_id,
      contact_attributes: create_contact_attributes,
      skip_runtime_events: true
    ).perform
  rescue ActiveRecord::RecordInvalid => e
    recover_existing_contact_inbox!(e)
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
      return canonical_remote_jid if lid_only_identity?

      candidate = canonical_remote_jid.to_s.split('@').first.to_s.gsub(/\D/, '')
      candidate.presence if candidate.present? && candidate != '0'
    end
  end

  def phone_number
    return if lid_only_identity?
    return if source_id.blank?

    "+#{source_id}"
  end

  def display_name
    value = preferred_display_name || phone_number || source_id
    value.to_s.truncate(100)
  end

  def profile_pic_url
    contact_payload[:profilePicUrl].presence
  end

  def create_contact_attributes
    {
      name: display_name,
      phone_number: phone_number,
      identifier: contact_identifier,
      additional_attributes: additional_attributes,
      avatar_url: profile_pic_url
    }.compact
  end

  def additional_attributes
    {
      raw_jid: raw_remote_jid,
      canonical_jid: canonical_remote_jid,
      lid_jid: lid_jid,
      provisional_whatsapp_identity: lid_only_identity?,
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
    updates[:identifier] = contact_identifier if contact.identifier.blank? && contact_identifier.present?

    if should_replace_contact_name?(contact)
      updates[:name] = display_name
    end

    return if updates.blank?

    contact.skip_runtime_events = true
    contact.update!(updates)
  rescue ActiveRecord::RecordInvalid => e
    raise unless identifier_conflict?(e, updates)

    merge_identifier_contact!(target_contact: contact)
    contact.reload
    retry
  end

  def sync_avatar(contact)
    return if profile_pic_url.blank?

    Avatar::AvatarFromUrlJob.perform_later(contact, profile_pic_url)
  end

  def preferred_display_name
    [contact_payload[:pushName], contact_payload[:name]].find do |value|
      value.present? && !placeholder_display_name?(value) && !technical_identity_name?(value)
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
    return true if technical_identity_name?(contact.name, contact: contact)
    return true if contact.name == contact.phone_number
    return true if phone_number.present? && contact.name == phone_number

    normalized_name = contact.name.to_s.gsub(/\D/, '')
    normalized_phone = phone_number.to_s.gsub(/\D/, '')
    normalized_name == normalized_phone
  end

  def technical_identity_name?(value, contact: nil)
    normalized = value.to_s.strip
    return false if normalized.blank?

    identity_aliases_for(contact).include?(normalized)
  end

  def identity_aliases_for(contact = nil)
    aliases = [
      source_id,
      raw_remote_jid,
      canonical_remote_jid,
      lid_jid,
      contact_identifier
    ]

    if contact.present?
      attributes = (contact.additional_attributes || {}).deep_stringify_keys
      aliases.concat([
        attributes['raw_jid'],
        attributes['canonical_jid'],
        attributes['lid_jid'],
        contact.identifier
      ])
    end

    aliases
      .filter_map { |value| normalized_identity_aliases(value) }
      .flatten
      .uniq
  end

  def normalized_identity_aliases(value)
    normalized = value.to_s.strip
    return if normalized.blank?

    aliases = [normalized]
    aliases << normalized.delete_prefix('whatsapp_web:')

    if normalized.include?('@')
      aliases << normalized.split('@').first
    end

    aliases.uniq
  end

  def ignored_remote_jid?
    [raw_remote_jid, canonical_remote_jid].compact.any? { |jid| channel.ignored_remote_jid?(jid) }
  end

  def supported_personal_remote_jid?
    canonical_remote_jid.end_with?('@s.whatsapp.net', '@lid')
  end

  def lid_jid
    @lid_jid ||= [contact_payload[:remoteLid], raw_remote_jid, canonical_remote_jid]
      .filter_map { |value| value.to_s.presence }
      .find { |jid| jid.end_with?('@lid') }
  end

  def lid_only_identity?
    canonical_remote_jid.end_with?('@lid')
  end

  def contact_identifier
    return if lid_jid.blank?

    "whatsapp_web:#{lid_jid}"
  end

  def identifier_conflict?(error, updates)
    updates[:identifier].present? && error.record.errors.of_kind?(:identifier, :taken)
  end

  def recover_existing_contact_inbox!(error)
    raise unless recoverable_builder_conflict?(error)

    contact = conflicting_existing_contact
    raise error if contact.blank?

    contact.skip_runtime_events = true
    sync_existing_contact(contact)

    ContactInboxBuilder.new(
      contact: contact,
      inbox: channel.inbox,
      source_id: source_id
    ).perform
  end

  def recoverable_builder_conflict?(error)
    return false unless error.record.is_a?(Contact)

    error.record.errors.of_kind?(:phone_number, :taken) ||
      error.record.errors.of_kind?(:identifier, :taken)
  end

  def conflicting_existing_contact
    @conflicting_existing_contact ||= begin
      account_contacts = channel.inbox.account.contacts

      account_contacts.find_by(identifier: contact_identifier).presence ||
        account_contacts.find_by(phone_number: phone_number).presence
    end
  end

  def merge_identifier_contact!(target_contact:)
    source_contact = channel.inbox.account.contacts.find_by(identifier: contact_identifier)
    return if source_contact.blank? || source_contact.id == target_contact.id

    ActiveRecord::Base.transaction do
      merge_contact_records!(source_contact: source_contact, target_contact: target_contact)
    end
  end

  def merge_contact_records!(source_contact:, target_contact:)
    now = Time.current

    source_contact.contact_inboxes.update_all(contact_id: target_contact.id, updated_at: now)
    Conversation.where(contact_id: source_contact.id).update_all(contact_id: target_contact.id, updated_at: now)
    Message.where(sender_type: 'Contact', sender_id: source_contact.id).update_all(sender_id: target_contact.id, updated_at: now)

    {
      'Note' => :contact_id,
      'CampaignDelivery' => :contact_id,
      'CsatSurveyResponse' => :contact_id,
      'Scheduling::Appointment' => :contact_id
    }.each do |class_name, foreign_key|
      klass = class_name.safe_constantize
      next if klass.blank?

      klass.where(foreign_key => source_contact.id).update_all(foreign_key => target_contact.id, updated_at: now)
    end

    merged_additional_attributes = (source_contact.additional_attributes || {}).deep_stringify_keys
      .merge((target_contact.additional_attributes || {}).deep_stringify_keys)

    source_contact.update_columns(identifier: nil, updated_at: now)

    target_contact.skip_runtime_events = true
    target_contact.update!(
      additional_attributes: merged_additional_attributes,
      name: preferred_contact_name(target_contact, source_contact),
      phone_number: target_contact.phone_number.presence || source_contact.phone_number,
      identifier: target_contact.identifier.presence || source_contact.identifier
    )

    source_contact.skip_runtime_events = true
    source_contact.destroy!
  rescue ActiveRecord::RecordNotDestroyed
    source_contact.update_columns(identifier: nil, updated_at: now)
  end

  def preferred_contact_name(target_contact, source_contact)
    return display_name if should_replace_contact_name?(target_contact)
    return source_contact.name if target_contact.name.blank? && source_contact.name.present?

    target_contact.name
  end
end
