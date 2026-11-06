# frozen_string_literal: true

class Contacts::ChannelSyncMergeService
  def self.merge_crm_deal_contacts!(base_contact:, mergee_contact:)
    return unless ActiveRecord::Base.connection.data_source_exists?('crm_deal_contacts')

    Crm::DealContact.where(contact_id: mergee_contact.id, account_id: base_contact.account_id).find_each do |deal_contact|
      existing_link = Crm::DealContact.find_by(deal_id: deal_contact.deal_id, contact_id: base_contact.id)
      if existing_link
        merge_duplicate_deal_contact!(existing_link, deal_contact)
      else
        deal_contact.update!(contact_id: base_contact.id)
      end
    end
  end

  def self.merge_duplicate_deal_contact!(existing_link, duplicate_link)
    duplicate_was_primary = duplicate_link.primary?
    duplicate_link.destroy!
    existing_link.update!(primary: true) if duplicate_was_primary && !existing_link.primary?
  end
  private_class_method :merge_duplicate_deal_contact!

  def initialize(source_contact:, target_contact:, name_source_inbox: nil, &preferred_name_block)
    @source_contact = source_contact
    @target_contact = target_contact
    @name_source_inbox = name_source_inbox
    @preferred_name_block = preferred_name_block
  end

  def perform
    ActiveRecord::Base.transaction { perform_merge }
  rescue Contacts::ReferenceMergeService::UnsafeMergeError
    false
  end

  private

  def perform_merge
    # Lock order: phone identity lock first, then appointments, contacts and their chats (see the number transfer).
    Contacts::PhoneIdentityLock.acquire!(account_id: target_contact.account_id)
    source_contact.reload
    target_contact.reload
    Contacts::PatientIdentityMergeGuard.lock_patient_bindings!(source_contact, target_contact)
    return false unless Contacts::PatientIdentityMergeGuard.allowed?(source_contact: source_contact, target_contact: target_contact)

    reference_merger = build_reference_merger
    reference_merger.prepare!

    now = Time.current
    reassign_core_associations!(now)
    reference_merger.reassign_remaining_references!
    unify_labels!
    finalize_contact_merge!(now)
  end

  attr_reader :source_contact, :target_contact, :name_source_inbox, :preferred_name_block

  def build_reference_merger
    Contacts::ReferenceMergeService.new(
      account: target_contact.account,
      base_contact: target_contact,
      mergee_contact: source_contact,
      lock_patient_bindings: false
    )
  end

  def reassign_core_associations!(now)
    reassign_inbox_and_message_records!(now)
    consolidate_conversations_and_threads!(now)
    self.class.merge_crm_deal_contacts!(base_contact: target_contact, mergee_contact: source_contact)
  end

  # rubocop:disable Rails/SkipsModelValidations
  def reassign_inbox_and_message_records!(now)
    # Duplicate merge changes the captured patient ID without dispatching another provider write.
    Scheduling::Appointment.where(account_id: target_contact.account_id, patient_contact_id: source_contact.id)
                           .update_all(patient_contact_id: target_contact.id, updated_at: now)
    source_contact.contact_inboxes.update_all(contact_id: target_contact.id, updated_at: now)
    ContactChannelProfile.where(contact_id: source_contact.id).update_all(contact_id: target_contact.id, updated_at: now)
    Message.where(sender_type: 'Contact', sender_id: source_contact.id).update_all(sender_id: target_contact.id, updated_at: now)
  end

  def consolidate_conversations_and_threads!(now)
    Conversation.where(contact_id: source_contact.id).update_all(contact_id: target_contact.id, updated_at: now)
    Conversations::SingleDialogConsolidator.new(account: target_contact.account, contact_id: target_contact.id).perform
    thread_merge = Contacts::CommunicationThreadMergeService.new(base_contact: target_contact, mergee_contact: source_contact)
    thread_merge.perform
    thread_merge.refresh_status!
    Note.where(contact_id: source_contact.id, account_id: source_contact.account_id)
        .update_all(contact_id: target_contact.id, updated_at: now)
  end

  # The labels of the card that goes away stay with the person (see ContactMergeAction#merge_labels).
  def unify_labels!
    Labels::UnifiedAssignmentService.unify(
      contact: target_contact,
      extra_labels: Labels::UnifiedAssignmentService.person_labels(contact_id: source_contact.id)
    )
  end

  def finalize_contact_merge!(now)
    clear_source_identifier!(now)
    update_target_contact!
    destroy_source_contact!
  rescue ActiveRecord::RecordNotDestroyed
    clear_source_identifier!(now)
    true
  end

  def clear_source_identifier!(now)
    source_contact.update_columns(identifier: nil, updated_at: now) if source_contact.identifier.present?
  end
  # rubocop:enable Rails/SkipsModelValidations

  def update_target_contact!
    target_contact.skip_runtime_events = true
    target_contact.update!(
      additional_attributes: build_merged_additional_attributes,
      name: resolved_contact_name,
      phone_number: target_contact.phone_number.presence || source_contact.phone_number,
      identifier: target_contact.identifier.presence || source_contact.identifier
    )
  end

  def destroy_source_contact!
    source_contact.skip_runtime_events = true
    source_contact.destroy!
    true
  end

  def resolved_contact_name
    return target_contact.name if manual_name?(target_contact)
    return source_contact.name if transfer_manual_name?

    preferred_name_block ? preferred_name_block.call : target_contact.name
  end

  def build_merged_additional_attributes
    source_attrs = stringified_hash(source_contact.additional_attributes)
    target_attrs = stringified_hash(target_contact.additional_attributes)
    merged = source_attrs.merge(target_attrs)
    merged_profiles = merge_channel_profile_hashes(source_attrs['channel_profiles'], target_attrs['channel_profiles'])
    merged['channel_profiles'] = merged_profiles if merged_profiles.present?
    if transfer_manual_name?
      merged = target_contact.merge_display_source(
        additional_attributes: merged,
        key: Contact::PRIMARY_NAME_SOURCE_KEY,
        source: source_contact.primary_name_source
      )
    end
    merged
  end

  def transfer_manual_name?
    return false unless matching_name_source_accounts?
    return false unless manual_name?(source_contact)
    return false if manual_name?(target_contact)
    return false if source_contact.name.blank?

    !different_primary_name_inbox?
  end

  def different_primary_name_inbox?
    selected_source = target_contact.primary_name_source
    selected_source.present? && selected_source == target_contact.resolved_primary_name_source &&
      selected_source['inbox_id'].to_i != name_source_inbox.id
  end

  def matching_name_source_accounts?
    name_source_inbox.present? && [source_contact.account_id, target_contact.account_id].all?(name_source_inbox.account_id)
  end

  def manual_name?(contact)
    contact.primary_name_source['kind'] == Contact::DISPLAY_SOURCE_KIND_MANUAL
  end

  def merge_channel_profile_hashes(source_profiles, target_profiles)
    stringified_hash(source_profiles).merge(stringified_hash(target_profiles)) do |_key, old_val, new_val|
      stringified_hash(old_val).merge(stringified_hash(new_val))
    end
  end

  def stringified_hash(value)
    value.is_a?(Hash) ? value.deep_stringify_keys : {}
  end
end
