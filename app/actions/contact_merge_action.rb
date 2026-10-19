# verified_identifier: set only by the widget identify path after HMAC verification; a patient card may then absorb the
# visitor when that verified identifier is the card's own identifier.
class ContactMergeAction
  include Events::Types
  pattr_initialize [:account!, :base_contact!, :mergee_contact!, { verified_identifier: nil }]

  def perform
    # This case happens when an agent updates a contact email in dashboard,
    # while the contact also update his email via email collect box
    return @base_contact if base_contact.id == mergee_contact.id

    ActiveRecord::Base.transaction do
      # Lock order: phone identity lock first (the base update re-takes it), then the bulk reassignments.
      Contacts::PhoneIdentityLock.acquire!(account_id: @account.id)
      validate_contacts
      merge_conversations
      merge_communication_threads
      merge_messages
      merge_contact_inboxes
      merge_contact_channel_profiles
      merge_crm_deal_contacts
      merge_contact_notes
      merge_remaining_contact_references
      merge_and_remove_mergee_contact
    end
    @base_contact
  end

  private

  def validate_contacts
    raise StandardError, 'contact does not belong to the account' unless belongs_to_account?(@base_contact) && belongs_to_account?(@mergee_contact)
    return if Contacts::PatientIdentityMergeGuard.explicit_merge_allowed?(base_contact: @base_contact, mergee_contact: @mergee_contact)
    return if verified_identifier.present? && @base_contact.identifier == verified_identifier.to_s

    raise Contacts::ReferenceMergeService::UnsafeMergeError,
          'A separate MedElement patient card can only be merged with a contact that has the same patient code or IIN.'
  end

  def belongs_to_account?(contact)
    @account.id == contact.account_id
  end

  def merge_conversations
    bulk_reassign(
      Conversation.where(contact_id: @mergee_contact.id),
      contact_id: @base_contact.id
    )
    Conversations::SingleDialogConsolidator.new(account: @account, contact_id: @base_contact.id).perform
  end

  def merge_communication_threads
    bulk_reassign(
      CommunicationThread.where(contact_id: @mergee_contact.id),
      contact_id: @base_contact.id
    )
  end

  def merge_contact_notes
    bulk_reassign(
      Note.where(contact_id: @mergee_contact.id, account_id: @mergee_contact.account_id),
      contact_id: @base_contact.id
    )
  end

  def merge_remaining_contact_references
    Contacts::ReferenceMergeService.new(
      account: @account,
      base_contact: @base_contact,
      mergee_contact: @mergee_contact
    ).perform
  end

  def merge_messages
    bulk_reassign(
      Message.where(sender: @mergee_contact),
      sender_id: @base_contact.id,
      sender_type: @base_contact.class.base_class.name
    )
  end

  def merge_contact_inboxes
    bulk_reassign(
      ContactInbox.where(contact_id: @mergee_contact.id),
      contact_id: @base_contact.id
    )
  end

  def merge_contact_channel_profiles
    bulk_reassign(
      ContactChannelProfile.where(contact_id: @mergee_contact.id),
      contact_id: @base_contact.id
    )
  end

  def merge_crm_deal_contacts
    Crm::DealContact.where(contact_id: @mergee_contact.id, account_id: @account.id).find_each do |deal_contact|
      existing_link = Crm::DealContact.find_by(deal_id: deal_contact.deal_id, contact_id: @base_contact.id)
      if existing_link
        merge_duplicate_deal_contact(existing_link, deal_contact)
      else
        deal_contact.update!(contact_id: @base_contact.id)
      end
    end
  end

  def merge_duplicate_deal_contact(existing_link, duplicate_link)
    duplicate_was_primary = duplicate_link.primary?
    duplicate_link.destroy!
    existing_link.update!(primary: true) if duplicate_was_primary && !existing_link.primary?
  end

  def merge_and_remove_mergee_contact
    mergable_attribute_keys = %w[identifier name last_name middle_name email phone_number additional_attributes custom_attributes]
    base_contact_attributes = base_contact.attributes.slice(*mergable_attribute_keys).compact_blank
    mergee_contact_attributes = mergee_contact.attributes.slice(*mergable_attribute_keys).compact_blank

    # attributes in base contact are given preference
    merged_attributes = mergee_contact_attributes.deep_merge(base_contact_attributes)
    if merged_attributes['custom_attributes'].present?
      merged_attributes['custom_attributes'] = reconcile_merged_custom_attributes(
        merged_attributes['custom_attributes'],
        primary_phone: merged_attributes['phone_number']
      )
    end

    @mergee_contact.reload.destroy!
    Rails.configuration.dispatcher.dispatch(CONTACT_MERGED, Time.zone.now, contact: @base_contact,
                                                                           tokens: [@base_contact.contact_inboxes.filter_map(&:pubsub_token)])
    @base_contact.update!(merged_attributes)
  end

  def reconcile_merged_custom_attributes(raw_attributes, primary_phone:)
    custom = raw_attributes.deep_stringify_keys
    merge_patient_codes!(custom)
    merge_secondary_phones!(custom, primary_phone)
    clear_resolved_phone_conflict!(custom, primary_phone)
    custom
  end

  def merge_patient_codes!(custom)
    primary_code = custom['medelement_patient_code'].to_s.presence
    merged_codes = all_patient_codes - [primary_code].compact
    custom['medelement_merged_patient_codes'] = merged_codes if merged_codes.any?
  end

  def all_patient_codes
    [base_contact, mergee_contact].flat_map do |contact|
      attrs = contact.custom_attributes.to_h
      [attrs['medelement_patient_code'], *Array(attrs['medelement_merged_patient_codes'])]
    end.compact_blank.map(&:to_s).uniq
  end

  def merge_secondary_phones!(custom, primary_phone)
    combined = (
      Array(base_contact.custom_attributes.to_h['secondary_phones']) +
      Array(mergee_contact.custom_attributes.to_h['secondary_phones'])
    ).compact_blank.uniq
    return if combined.empty?

    normalized_primary = Integrations::Medelement::PhoneNumber.normalize(primary_phone)
    custom['secondary_phones'] = combined.reject do |phone|
      normalized_primary.present? && Integrations::Medelement::PhoneNumber.normalize(phone) == normalized_primary
    end
  end

  def clear_resolved_phone_conflict!(custom, primary_phone)
    comment = custom['phone_conflict_comment'].to_s
    if comment.present? && (primary_phone.present? || comment.include?("##{@mergee_contact.id}") || comment.include?("##{@base_contact.id}"))
      custom.delete('phone_conflict_comment')
    end
    Contacts::SharedPhone.clear_share!(custom) if primary_phone.present?
  end

  def bulk_reassign(relation, attributes)
    # Bulk FK remaps are the hot path for large merges; row-by-row updates
    # trigger callbacks and can blow through the request timeout.
    # rubocop:disable Rails/SkipsModelValidations
    relation.update_all(attributes.merge(updated_at: Time.current))
    # rubocop:enable Rails/SkipsModelValidations
  end
end
