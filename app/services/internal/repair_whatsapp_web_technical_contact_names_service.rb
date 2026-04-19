class Internal::RepairWhatsappWebTechnicalContactNamesService
  GENERIC_ROLE_DISPLAY_NAMES = %w[reception].freeze

  def initialize(account: nil, batch_size: 500)
    @account = account
    @batch_size = batch_size
  end

  def perform
    repaired_count = 0

    repairable_contacts.find_in_batches(batch_size: @batch_size) do |batch|
      batch.each do |contact|
        repaired_count += 1 if repair_contact(contact)
      end
    end

    repaired_count
  end

  private

  def repairable_contacts
    base_scope = @account ? @account.contacts : Contact.all

    base_scope
      .joins(contact_inboxes: :inbox)
      .where(inboxes: { channel_type: 'Channel::WhatsappWeb' })
      .where.not(phone_number: [nil, ''])
      .includes(contact_inboxes: :inbox)
      .distinct
  end

  def repair_contact(contact)
    target_name = preferred_target_name(contact)
    return false if target_name.blank?

    contact_repaired = repair_contact_record(contact, target_name)
    profile_repaired = repair_channel_profiles(contact, target_name)

    contact_repaired || profile_repaired
  end

  def repair_contact_record(contact, target_name)
    return false unless repairable_contact_name?(contact)
    return false if contact.name == target_name

    contact.skip_runtime_events = true
    contact.update!(name: target_name)
    true
  end

  def repair_channel_profiles(contact, target_name)
    repaired_any = false

    contact.contact_channel_profiles.where(provider: 'whatsapp_web').each do |profile|
      repaired_any ||= repair_channel_profile(profile, target_name)
    end

    repaired_any
  end

  def repair_channel_profile(profile, target_name)
    return false unless repairable_profile_name?(profile)

    current_profile_data = (profile.profile_data || {}).deep_stringify_keys
    resolved_phone_number = profile.phone_number.presence || profile.contact.phone_number.presence
    updates = {}

    updates[:display_name] = target_name if profile.display_name != target_name
    updates[:phone_number] = resolved_phone_number if profile.phone_number.blank? && resolved_phone_number.present?

    merged_profile_data = current_profile_data.merge(
      'display_name' => target_name,
      'name' => target_name
    )
    merged_profile_data['phone_number'] = resolved_phone_number if resolved_phone_number.present?
    updates[:profile_data] = merged_profile_data if merged_profile_data != current_profile_data

    return false if updates.blank?

    profile.update!(updates)
    true
  end

  def technical_contact_name?(contact)
    current_name = contact.name.to_s.strip
    return false if current_name.blank?

    return true if normalized_digits(current_name).present? &&
                   normalized_digits(current_name) == normalized_digits(contact.phone_number)

    identity_aliases_for(contact).include?(current_name)
  end

  def repairable_contact_name?(contact)
    technical_contact_name?(contact) || placeholder_display_name?(contact.name)
  end

  def technical_profile_name?(profile)
    current_name = profile.display_name.to_s.strip
    return false if current_name.blank?

    profile_phone_number = profile.phone_number.presence || profile.contact.phone_number
    return true if normalized_digits(current_name).present? &&
                   normalized_digits(current_name) == normalized_digits(profile_phone_number)

    profile_identity_aliases_for(profile).include?(current_name)
  end

  def repairable_profile_name?(profile)
    technical_profile_name?(profile) || placeholder_display_name?(profile.display_name)
  end

  def preferred_target_name(contact)
    whatsapp_profile_display_name(contact).presence || contact.phone_number.to_s.presence
  end

  def whatsapp_profile_display_name(contact)
    contact.contact_channel_profiles
           .where(provider: 'whatsapp_web')
           .sort_by { |profile| [profile.last_synced_at || profile.updated_at, profile.id] }
           .reverse
           .filter_map do |profile|
      value = profile.display_name.to_s.strip
      next if value.blank? || placeholder_display_name?(value) || technical_profile_name?(profile)

      value
    end
      .first
  end

  def identity_aliases_for(contact)
    attributes = (contact.additional_attributes || {}).deep_stringify_keys

    aliases = [
      contact.identifier,
      attributes['raw_jid'],
      attributes['canonical_jid'],
      attributes['lid_jid']
    ]

    contact.contact_inboxes.each do |contact_inbox|
      next unless contact_inbox.inbox&.channel_type == 'Channel::WhatsappWeb'

      aliases << contact_inbox.source_id
    end

    aliases
      .filter_map { |value| normalized_aliases(value) }
      .flatten
      .uniq
  end

  def profile_identity_aliases_for(profile)
    attributes = (profile.profile_data || {}).deep_stringify_keys

    [
      profile.identifier,
      profile.source_id,
      attributes['raw_jid'],
      attributes['canonical_jid'],
      attributes['lid_jid']
    ]
      .filter_map { |value| normalized_aliases(value) }
      .flatten
      .uniq
  end

  def normalized_aliases(value)
    normalized = value.to_s.strip
    return if normalized.blank?

    aliases = [normalized]
    aliases << normalized.delete_prefix('whatsapp_web:')
    aliases << normalized.split('@').first if normalized.include?('@')
    aliases.uniq
  end

  def normalized_digits(value)
    value.to_s.gsub(/\D/, '')
  end

  def placeholder_display_name?(value)
    normalized = I18n.transliterate(value.to_s).strip.downcase
    return true if normalized.blank?
    return true if %w[voce you].include?(normalized)
    return true if GENERIC_ROLE_DISPLAY_NAMES.include?(normalized)

    normalized.gsub(/[^[:alnum:]]+/, '').blank?
  end
end
