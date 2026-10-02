class CommunicationThreads::MarkUnreadService
  def initialize(communication_thread:, accessible_links:, current_user:)
    @communication_thread = communication_thread
    @accessible_links = accessible_links
    @current_user = current_user
  end

  def perform
    marked_conversations = conversations.select { |conversation| mark_conversation_unread(conversation) }

    refresh_communication_thread!
    updated_thread = communication_thread.reload
    enqueue_realtime_update(updated_thread, marked_conversations.max_by(&:last_activity_at)) if marked_conversations.any?
    updated_thread
  end

  private

  attr_reader :communication_thread, :accessible_links, :current_user

  def conversations
    @conversations ||= accessible_links.includes(:conversation).filter_map(&:conversation)
  end

  def mark_conversation_unread(conversation)
    last_incoming_message = Message.without_imported_history
                                   .where(
                                     account_id: conversation.account_id,
                                     conversation_id: conversation.id,
                                     private: false
                                   )
                                   .incoming
                                   .reorder(created_at: :desc, id: :desc)
                                   .first
    return false if last_incoming_message.blank?

    last_seen_at = last_incoming_message.created_at - 1.second
    Conversations::LastSeenUpdater.new(conversation: conversation).perform(
      last_seen_at: last_seen_at,
      update_assignee: true,
      refresh_communication_thread: false,
      broadcast_read_state: false,
      allow_regression: true,
      actor: current_user
    )
    true
  end

  def refresh_communication_thread!
    latest_accessible_conversation&.refresh_communication_thread!
  end

  def latest_accessible_conversation
    conversations.max_by do |conversation|
      [conversation.last_activity_at || conversation.updated_at, conversation.id]
    end
  end

  def enqueue_realtime_update(updated_thread, source_conversation)
    CommunicationThreads::RealtimeUpdateJob.perform_later(
      communication_thread_id: updated_thread.id,
      source_conversation_id: source_conversation.id,
      source_event: 'conversation.read',
      performer_id: current_user.id
    )
  end
end
