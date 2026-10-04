module Crm::Deals::UpsertOwnership
  private

  def resolve_deal_owner(conversation:, communication_thread:, primary_contact:)
    return resolve_optional_record(:owner_id, account.users, current: deal.owner) if params.key?(:owner_id)
    return deal.owner if deal.persisted?

    default_owner_for_source(
      conversation: conversation,
      communication_thread: communication_thread,
      primary_contact: primary_contact
    )
  end

  def default_owner_for_source(conversation:, communication_thread:, primary_contact:)
    source_owner_candidates(
      conversation: conversation,
      communication_thread: communication_thread,
      primary_contact: primary_contact
    ).find(&:present?) || actor
  end

  def source_owner_candidates(conversation:, communication_thread:, primary_contact:)
    contact_owner = source_contact_owner(conversation, communication_thread, primary_contact)
    return legacy_owner_candidates(contact_owner, conversation, communication_thread) if legacy_conversation_source?

    thread_owner_candidates(contact_owner, conversation, communication_thread)
  end

  def source_contact_owner(conversation, communication_thread, primary_contact)
    primary_contact&.owner || communication_thread_contact_owner(communication_thread) || conversation_contact_owner(conversation)
  end

  def communication_thread_contact_owner(communication_thread)
    communication_thread&.contact&.owner
  end

  def conversation_contact_owner(conversation)
    conversation&.contact&.owner
  end

  def legacy_conversation_source?
    params[:originating_communication_thread_id].blank?
  end

  def legacy_owner_candidates(contact_owner, conversation, communication_thread)
    [contact_owner, conversation&.assignee, communication_thread&.assignee]
  end

  def thread_owner_candidates(contact_owner, conversation, communication_thread)
    [
      contact_owner,
      communication_thread&.assignee,
      default_owner_from_thread_conversations(communication_thread),
      conversation&.assignee
    ]
  end

  def default_owner_from_thread_conversations(communication_thread)
    return if communication_thread.blank?

    communication_thread.conversations
                        .where.not(assignee_id: nil)
                        .order(Arel.sql('conversations.last_activity_at DESC NULLS LAST, conversations.id DESC'))
                        .first&.assignee
  end

  def resolve_originating_conversation
    return deal.originating_conversation unless params.key?(:originating_conversation_id)
    return if params[:originating_conversation_id].blank?

    value = params[:originating_conversation_id].to_s.strip
    account.conversations.find_by(id: value) || account.conversations.find_by!(display_id: value)
  end

  def resolve_originating_communication_thread
    return requested_communication_thread if params.key?(:originating_communication_thread_id)

    deal.originating_communication_thread if deal.persisted?
  end

  def requested_communication_thread
    raw_value = params[:originating_communication_thread_id]
    return if raw_value.blank?

    value = raw_value.to_s.strip
    scope = CommunicationThread.where(account_id: account.id)
    scope.find_by(display_id: value) || scope.find(value)
  end

  def validate_source_contacts!(conversation:, communication_thread:)
    return if conversation.blank? || communication_thread.blank?
    return if conversation.contact_id == communication_thread.contact_id

    validation_error!(
      'originating_communication_thread_id',
      'must reference the same contact as originating_conversation_id'
    )
  end
end
