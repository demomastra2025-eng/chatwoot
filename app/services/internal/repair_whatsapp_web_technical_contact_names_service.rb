class Internal::RepairWhatsappWebTechnicalContactNamesService
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
    return false unless technical_contact_name?(contact)

    target_name = contact.phone_number.to_s.presence
    return false if target_name.blank? || contact.name == target_name

    contact.skip_runtime_events = true
    contact.update!(name: target_name)
    true
  end

  def technical_contact_name?(contact)
    current_name = contact.name.to_s.strip
    return false if current_name.blank?

    return true if normalized_digits(current_name).present? &&
      normalized_digits(current_name) == normalized_digits(contact.phone_number)

    identity_aliases_for(contact).include?(current_name)
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
end
