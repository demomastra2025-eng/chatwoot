class ContactMergeAction
  include Events::Types
  pattr_initialize [:account!, :base_contact!, :mergee_contact!]

  def perform
    # This case happens when an agent updates a contact email in dashboard,
    # while the contact also update his email via email collect box
    return @base_contact if base_contact.id == mergee_contact.id

    ActiveRecord::Base.transaction do
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
    return if belongs_to_account?(@base_contact) && belongs_to_account?(@mergee_contact)

    raise StandardError, 'contact does not belong to the account'
  end

  def belongs_to_account?(contact)
    @account.id == contact.account_id
  end

  def merge_conversations
    bulk_reassign(
      Conversation.where(contact_id: @mergee_contact.id),
      contact_id: @base_contact.id
    )
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
    mergable_attribute_keys = %w[identifier name email phone_number additional_attributes custom_attributes]
    base_contact_attributes = base_contact.attributes.slice(*mergable_attribute_keys).compact_blank
    mergee_contact_attributes = mergee_contact.attributes.slice(*mergable_attribute_keys).compact_blank

    # attributes in base contact are given preference
    merged_attributes = mergee_contact_attributes.deep_merge(base_contact_attributes)

    @mergee_contact.reload.destroy!
    Rails.configuration.dispatcher.dispatch(CONTACT_MERGED, Time.zone.now, contact: @base_contact,
                                                                           tokens: [@base_contact.contact_inboxes.filter_map(&:pubsub_token)])
    @base_contact.update!(merged_attributes)
  end

  def bulk_reassign(relation, attributes)
    # Bulk FK remaps are the hot path for large merges; row-by-row updates
    # trigger callbacks and can blow through the request timeout.
    # rubocop:disable Rails/SkipsModelValidations
    relation.update_all(attributes.merge(updated_at: Time.current))
    # rubocop:enable Rails/SkipsModelValidations
  end
end
