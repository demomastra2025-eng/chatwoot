class CommunicationThreads::MarkUnreadService
  def initialize(communication_thread:, accessible_links:)
    @communication_thread = communication_thread
    @accessible_links = accessible_links
  end

  def perform
    conversations.each { |conversation| mark_conversation_unread(conversation) }

    refresh_communication_thread!
    communication_thread.reload
  end

  private

  attr_reader :communication_thread, :accessible_links

  def conversations
    @conversations ||= accessible_links.includes(:conversation).filter_map(&:conversation)
  end

  def mark_conversation_unread(conversation)
    last_incoming_message = conversation.messages.incoming.last
    return if last_incoming_message.blank?

    Conversations::LastSeenUpdater.new(conversation: conversation).perform(
      last_seen_at: last_incoming_message.created_at - 1.second,
      update_assignee: true,
      refresh_communication_thread: false
    )
  end

  def refresh_communication_thread!
    latest_accessible_conversation&.refresh_communication_thread!
  end

  def latest_accessible_conversation
    conversations.max_by do |conversation|
      [conversation.last_activity_at || conversation.updated_at, conversation.id]
    end
  end
end
