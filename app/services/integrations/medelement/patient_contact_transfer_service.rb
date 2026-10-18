class Integrations::Medelement::PatientContactTransferService
  MERGEABLE_ATTRIBUTE_KEYS = %w[identifier name last_name middle_name email additional_attributes custom_attributes].freeze

  def initialize(account:, source_contact:, destination_contact:)
    @account = account
    @source_contact = source_contact
    @destination_contact = destination_contact
  end

  def perform
    return destination_contact if source_contact.id == destination_contact.id

    sanitize_destination_owner!
    transfer_deal_contacts!
    transfer_reminders_with_channel_routes!
    Contacts::ReferenceMergeService.new(
      account: account,
      base_contact: destination_contact,
      mergee_contact: source_contact
    ).perform
    transfer_notes!
    transfer_labels!
    transfer_contact_attributes!
    destination_contact
  end

  private

  attr_reader :account, :source_contact, :destination_contact

  def sanitize_destination_owner!
    return if destination_contact.owner_id.blank? || account.users.exists?(id: destination_contact.owner_id)

    destination_contact.owner = nil
  end

  def transfer_reminders_with_channel_routes!
    return unless defined?(Reminder)

    Contacts::ReferenceMergeService.merge_appointment_references!(
      base_contact: destination_contact,
      mergee_contact: source_contact
    )
    # rubocop:disable Rails/SkipsModelValidations
    Reminder.where(account_id: account.id, target_contact_id: source_contact.id)
            .where('target_contact_inbox_id IS NOT NULL OR target_conversation_id IS NOT NULL')
            .update_all(
              target_contact_id: destination_contact.id,
              target_contact_inbox_id: nil,
              target_conversation_id: nil,
              updated_at: Time.current
            )
    # rubocop:enable Rails/SkipsModelValidations
  end

  def transfer_deal_contacts!
    Crm::DealContact.where(account_id: account.id, contact_id: source_contact.id).find_each do |deal_contact|
      existing_link = Crm::DealContact.find_by(deal_id: deal_contact.deal_id, contact_id: destination_contact.id)
      if existing_link
        duplicate_was_primary = deal_contact.primary?
        deal_contact.destroy!
        existing_link.update!(primary: true) if duplicate_was_primary && !existing_link.primary?
      else
        deal_contact.update!(contact_id: destination_contact.id)
      end
    end
  end

  def transfer_notes!
    # rubocop:disable Rails/SkipsModelValidations
    Note.where(account_id: account.id, contact_id: source_contact.id)
        .update_all(contact_id: destination_contact.id, updated_at: Time.current)
    # rubocop:enable Rails/SkipsModelValidations
  end

  def transfer_labels!
    destination_contact.label_list.add(*source_contact.label_list)
    destination_contact.save! if destination_contact.changed?
    source_contact.label_list = []
  end

  def transfer_contact_attributes!
    transfer_state = captured_transfer_state
    scrub_source_contact!
    apply_destination_contact!(transfer_state)
  end

  def scrub_source_contact!
    source_contact.skip_runtime_events = true
    source_contact.assign_attributes(scrubbed_source_attributes)
    source_contact.save!
  end

  def apply_destination_contact!(transfer_state)
    destination_contact.skip_runtime_events = true
    destination_contact.assign_attributes(transfer_state[:attributes])
    destination_contact.owner ||= transfer_state[:owner]
    destination_contact.company ||= transfer_state[:company]
    destination_contact.contact_type = transfer_state[:contact_type] if transfer_contact_type?(transfer_state[:contact_type])
    destination_contact.save!
  end

  def captured_transfer_state
    source_attributes = source_contact.attributes.slice(*MERGEABLE_ATTRIBUTE_KEYS).compact_blank
    destination_attributes = destination_contact.attributes.slice(*MERGEABLE_ATTRIBUTE_KEYS).compact_blank
    merged = source_attributes.deep_merge(destination_attributes)
    apply_source_patient_name!(merged, source_attributes) if medelement_source?
    sanitize_transferred_custom_attributes!(merged['custom_attributes']) if merged['custom_attributes'].is_a?(Hash)
    {
      attributes: merged,
      owner: valid_account_owner(source_contact.owner),
      company: source_contact.company,
      contact_type: source_contact.contact_type
    }
  end

  def valid_account_owner(user)
    user if user.present? && account.users.exists?(id: user.id)
  end

  def medelement_source?
    source_contact.custom_attributes.to_h['medelement_patient_code'].present?
  end

  def apply_source_patient_name!(merged, source_attributes)
    custom = source_contact.custom_attributes.to_h
    first_name = custom['medelement_first_name'].presence || source_attributes['name'].presence
    last_name = custom['medelement_last_name'].presence || source_attributes['last_name'].presence
    middle_name = custom['medelement_middle_name'].presence || source_attributes['middle_name'].presence
    merged['name'] = first_name if first_name.present?
    merged['last_name'] = last_name if last_name.present?
    merged['middle_name'] = middle_name if middle_name.present?
  end

  def sanitize_transferred_custom_attributes!(custom)
    return if destination_contact.phone_number.blank?

    Contacts::SharedPhone.clear_share!(custom)
    custom.delete('phone_conflict_comment')
    primary = Integrations::Medelement::PhoneNumber.normalize(destination_contact.phone_number)
    custom['secondary_phones'] = Array(custom['secondary_phones']).reject { |phone| phone == primary } if custom.key?('secondary_phones')
  end

  def transfer_contact_type?(source_contact_type)
    destination_contact.visitor? && source_contact_type != 'visitor'
  end

  def scrubbed_source_attributes
    {
      name: messenger_name,
      last_name: '',
      middle_name: '',
      email: nil,
      identifier: nil,
      company: nil,
      owner: nil,
      contact_type: :visitor,
      custom_attributes: {},
      additional_attributes: preserved_display_preferences
    }
  end

  def messenger_name
    source_contact.contact_channel_profiles
                  .where.not(display_name: [nil, ''])
                  .order(last_synced_at: :desc, id: :desc)
                  .pick(:display_name)
                  .presence || source_contact.name
  end

  def preserved_display_preferences
    preferences = source_contact.additional_attributes.to_h[Contact::DISPLAY_PREFERENCES_KEY]
    return {} if preferences.blank?

    { Contact::DISPLAY_PREFERENCES_KEY => preferences }
  end
end
