class Integrations::Medelement::PatientContactTransferService
  MERGEABLE_ATTRIBUTE_KEYS = %w[identifier name email additional_attributes custom_attributes].freeze

  def initialize(account:, source_contact:, destination_contact:)
    @account = account
    @source_contact = source_contact
    @destination_contact = destination_contact
  end

  def perform
    return destination_contact if source_contact.id == destination_contact.id

    Contacts::ReferenceMergeService.new(
      account: account,
      base_contact: destination_contact,
      mergee_contact: source_contact
    ).perform
    transfer_deal_contacts!
    transfer_notes!
    transfer_labels!
    transfer_contact_attributes!
    destination_contact
  end

  private

  attr_reader :account, :source_contact, :destination_contact

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
    {
      attributes: source_attributes.deep_merge(destination_attributes),
      owner: source_contact.owner,
      company: source_contact.company,
      contact_type: source_contact.contact_type
    }
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
