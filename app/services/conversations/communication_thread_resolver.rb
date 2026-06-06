class Conversations::CommunicationThreadResolver
  def initialize(conversation:)
    @conversation = conversation
  end

  def perform
    CommunicationThread.transaction do
      thread = existing_thread || build_thread
      thread.save! if thread.new_record?
      create_link!(thread)
      refresh_thread!(thread)
      thread
    end
  end

  private

  attr_reader :conversation

  def existing_thread
    conversation.communication_thread ||
      CommunicationThread.where(account_id: conversation.account_id, contact_id: conversation.contact_id)
                         .order(Arel.sql('last_activity_at DESC NULLS LAST'), id: :asc)
                         .first
  end

  def build_thread
    CommunicationThread.new(
      account_id: conversation.account_id,
      contact_id: conversation.contact_id,
      status: conversation.status,
      priority: conversation.priority,
      assignee_id: conversation.assignee_id,
      team_id: conversation.team_id,
      last_activity_at: conversation.last_activity_at,
      unread_count: conversation.unread_incoming_messages_count
    )
  end

  def create_link!(thread)
    return if CommunicationThreadConversation.exists?(communication_thread_id: thread.id, conversation_id: conversation.id)

    CommunicationThreadConversation.create!(
      account_id: conversation.account_id,
      communication_thread_id: thread.id,
      conversation_id: conversation.id,
      inbox_id: conversation.inbox_id,
      contact_inbox_id: conversation.contact_inbox_id,
      primary: CommunicationThreadConversation.where(communication_thread_id: thread.id).none?
    )
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
    return 'open' if conversations.any?(&:open?)
    return 'pending' if conversations.any?(&:pending?)
    return 'snoozed' if conversations.any?(&:snoozed?)

    'resolved'
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
    latest_routing_conversation(thread)&.assignee_id
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
    @linked_conversations[thread.id] ||= Conversation.where(
      id: CommunicationThreadConversation
        .where(communication_thread_id: thread.id)
        .select(:conversation_id)
    ).to_a
  end
end
