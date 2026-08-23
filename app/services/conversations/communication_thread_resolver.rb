require 'digest'

class Conversations::CommunicationThreadResolver
  def initialize(conversation:)
    # Conversation DB triggers populate display_id/uuid after insert and the
    # originating instance can still report those attributes as dirty. Locking
    # that instance raises in Active Record, so resolve against a fresh copy
    # without clearing the caller's saved_changes used by event dispatchers.
    @conversation = conversation&.persisted? ? conversation.class.find(conversation.id) : conversation
  end

  def perform
    return unless linkable_conversation?

    locked_account_id = conversation.account_id
    locked_contact_id = conversation.contact_id
    CommunicationThread.transaction do
      lock_contact_thread!(locked_account_id, locked_contact_id)
      conversation.lock!
      return unless linkable_conversation?
      return unless conversation.account_id == locked_account_id && conversation.contact_id == locked_contact_id

      previous_thread = raw_communication_thread
      thread = existing_thread || build_thread
      thread.save! if thread.new_record?
      create_or_update_link!(thread)
      reset_conversation_thread_associations
      refresh_thread!(thread)
      refresh_previous_thread!(previous_thread, thread)
      thread
    end
  end

  private

  attr_reader :conversation

  def lock_contact_thread!(account_id, contact_id)
    identity = "communication-thread:#{account_id}:#{contact_id}"
    lock_id = Digest::SHA256.digest(identity).unpack1('q>')

    ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{lock_id})")
  end

  def linkable_conversation?
    return false if conversation.blank? || conversation.destroyed? || conversation.marked_for_destruction?
    return false if conversation.account_id.blank? || conversation.contact_id.blank?
    return false if conversation.inbox_id.blank? || conversation.contact_inbox_id.blank?
    return false unless Inbox.exists?(id: conversation.inbox_id, account_id: conversation.account_id)
    return false unless Contact.exists?(id: conversation.contact_id, account_id: conversation.account_id)
    return false unless ContactInbox.exists?(id: conversation.contact_inbox_id, inbox_id: conversation.inbox_id, contact_id: conversation.contact_id)

    true
  end

  def existing_thread
    linked_thread = raw_communication_thread
    return linked_thread if linked_thread&.account_id == conversation.account_id && linked_thread.contact_id == conversation.contact_id

    CommunicationThread.where(account_id: conversation.account_id, contact_id: conversation.contact_id)
                       .order(Arel.sql('last_activity_at DESC NULLS LAST'), id: :asc)
                       .first
  end

  def raw_communication_thread
    conversation.association(:communication_thread).reader
  end

  def build_thread
    CommunicationThread.new(
      account_id: conversation.account_id,
      contact_id: conversation.contact_id,
      status: conversation.status,
      priority: conversation.priority,
      assignee_id: conversation.contact&.owner_id || conversation.assignee_id,
      team_id: conversation.team_id,
      last_activity_at: conversation.last_activity_at,
      unread_count: conversation.unread_incoming_messages_count
    )
  end

  def create_or_update_link!(thread)
    existing_link = CommunicationThreadConversation.find_by(
      account_id: conversation.account_id,
      conversation_id: conversation.id
    )
    return update_link!(existing_link, thread) if existing_link.present?

    CommunicationThreadConversation.create!(
      account_id: conversation.account_id,
      communication_thread_id: thread.id,
      conversation_id: conversation.id,
      inbox_id: conversation.inbox_id,
      contact_inbox_id: conversation.contact_inbox_id,
      primary: CommunicationThreadConversation.where(communication_thread_id: thread.id).none?
    )
  end

  def update_link!(link, thread)
    link.update!(
      communication_thread_id: thread.id,
      inbox_id: conversation.inbox_id,
      contact_inbox_id: conversation.contact_inbox_id,
      primary: link_primary_value(link, thread)
    )
  end

  def link_primary_value(link, thread)
    return link.primary? if link.communication_thread_id == thread.id

    CommunicationThreadConversation
      .where(communication_thread_id: thread.id)
      .where.not(id: link.id)
      .none?
  end

  def reset_conversation_thread_associations
    conversation.association(:communication_thread_conversation).reset
    conversation.association(:communication_thread).reset
  end

  def refresh_previous_thread!(previous_thread, current_thread)
    return if previous_thread.blank? || previous_thread.id == current_thread.id
    return unless previous_thread.account_id == conversation.account_id
    return unless previous_thread.contact&.account_id == conversation.account_id

    previous_thread.reload
    if previous_thread.communication_thread_conversations.exists?
      ensure_primary_link!(previous_thread)
      refresh_thread!(previous_thread)
    else
      previous_thread.destroy!
    end
  end

  def ensure_primary_link!(thread)
    primary_link_exists = CommunicationThreadConversation.exists?(
      communication_thread_id: thread.id,
      primary: true
    )
    return if primary_link_exists

    CommunicationThreadConversation
      .where(communication_thread_id: thread.id)
      .order(:created_at, :id)
      .first&.update!(primary: true)
  end

  def refresh_thread!(thread)
    thread.update!(
      status: aggregate_status(thread),
      priority: aggregate_priority(thread),
      assignee_id: aggregate_assignee_id(thread),
      team_id: aggregate_team_id(thread),
      last_activity_at: aggregate_last_activity_at(thread),
      unread_count: aggregate_unread_count(thread)
    )
  end

  def aggregate_status(thread)
    conversations = linked_conversations(thread)
    active_conversation = conversations
                          .reject(&:resolved?)
                          .max_by { |linked_conversation| status_sort_key(linked_conversation) }
    return active_conversation.status if active_conversation.present?

    'resolved'
  end

  def status_sort_key(linked_conversation)
    [
      linked_conversation.updated_at || linked_conversation.last_activity_at,
      linked_conversation.id
    ]
  end

  def aggregate_priority(thread)
    linked_conversations(thread).filter_map(&:priority).max_by { |priority| Conversation.priorities.fetch(priority) }
  end

  def aggregate_last_activity_at(thread)
    linked_conversations(thread).filter_map(&:last_activity_at).max || conversation.last_activity_at
  end

  def aggregate_unread_count(thread)
    linked_conversations(thread).sum(&:unread_incoming_messages_count)
  end

  def aggregate_assignee_id(thread)
    thread.contact&.owner_id || latest_routing_conversation(thread)&.assignee_id
  end

  def aggregate_team_id(thread)
    latest_routing_conversation(thread)&.team_id
  end

  def latest_routing_conversation(thread)
    linked_conversations(thread)
      .sort_by { |linked_conversation| routing_sort_key(linked_conversation) }
      .reverse
      .find { |linked_conversation| routed?(linked_conversation) }
  end

  def routing_sort_key(linked_conversation)
    [linked_conversation.last_activity_at || linked_conversation.updated_at, linked_conversation.id]
  end

  def routed?(linked_conversation)
    linked_conversation.assignee_id.present? || linked_conversation.team_id.present?
  end

  def linked_conversations(thread)
    @linked_conversations ||= {}
    @linked_conversations[thread.id] ||= Conversation.where(account_id: thread.account_id).where(
      id: CommunicationThreadConversation
        .where(communication_thread_id: thread.id)
        .select(:conversation_id)
    ).to_a
  end
end
