class ContactMergeAction
  include Events::Types
  pattr_initialize [:account!, :base_contact!, :mergee_contact!]

  def perform
    # This case happens when an agent updates a contact email in dashboard,
    # while the contact also update his email via email collect box
    return @base_contact if base_contact.id == mergee_contact.id

    ActiveRecord::Base.transaction do
      validate_contacts
      merge_owner
      merge_conversations
      merge_contact_inboxes
      merge_communication_threads
      merge_messages
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
    source_threads = CommunicationThread.where(account_id: @account.id, contact_id: @mergee_contact.id).lock.order(:id).to_a
    target_thread = CommunicationThread.where(account_id: @account.id, contact_id: @base_contact.id).lock.order(:id).first
    return if source_threads.empty? && target_thread.blank?

    if target_thread.blank?
      target_thread = source_threads.shift
      target_thread.update!(contact: @base_contact)
    end

    source_threads.each do |source_thread|
      source_thread.communication_thread_conversations.find_each do |link|
        link.update!(communication_thread: target_thread)
      end
      source_thread.destroy!
    end

    attach_conversations_to_thread!
    sync_merged_thread_routing!(target_thread)
  end

  def merge_owner
    return if @base_contact.owner_id.present? || @mergee_contact.owner_id.blank?

    @base_contact.update!(owner: @mergee_contact.owner)
  end

  def attach_conversations_to_thread!
    @base_contact.conversations.find_each do |conversation|
      Conversations::CommunicationThreadResolver.new(conversation: conversation).perform
    end
  end

  def sync_merged_thread_routing!(target_thread)
    CommunicationThreads::UpdateService.new(
      communication_thread: target_thread,
      params: {
        assignee_id: @base_contact.owner_id,
        team_id: target_thread.team_id,
        status: target_thread.status,
        priority: target_thread.priority
      }.with_indifferent_access,
      accessible_links: target_thread.communication_thread_conversations,
      actor: Current.user,
      source: 'contact_merge'
    ).perform
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
