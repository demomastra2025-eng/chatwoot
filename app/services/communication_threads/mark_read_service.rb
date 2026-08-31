class CommunicationThreads::MarkReadService
  attr_reader :last_seen_at

  def initialize(communication_thread:, current_user:, current_account:, accessible_links:)
    @communication_thread = communication_thread
    @current_user = current_user
    @current_account = current_account
    @accessible_links = accessible_links
  end

  def perform
    return communication_thread.reload unless mark_read_required?

    conversations.each do |conversation|
      conversation.skip_communication_thread_realtime = true
      Notification::MarkConversationReadService.new(
        user: current_user,
        account: current_account,
        conversation: conversation
      ).perform
      Conversations::MarkReadService.new(
        conversation: conversation,
        user: current_user,
        refresh_communication_thread: false
      ).perform
    end

    refresh_communication_thread!
    updated_thread = communication_thread.reload
    @last_seen_at = conversations.filter_map(&:agent_last_seen_at).max
    enqueue_realtime_update(updated_thread)
    updated_thread
  end

  def channel_read_states
    conversations.map do |conversation|
      {
        conversation_id: conversation.display_id,
        agent_last_seen_at: conversation.agent_last_seen_at&.to_i,
        unread_count: conversation.unread_incoming_messages_count
      }
    end
  end

  private

  attr_reader :communication_thread, :current_user, :current_account, :accessible_links

  def conversations
    links = accessible_links
    links = links.includes(:conversation) if links.respond_to?(:includes)
    @conversations ||= links.filter_map(&:conversation)
  end

  def unread_messages_exist?
    conversation_ids = conversations.map(&:id)
    return false if conversation_ids.blank?

    Message.joins(:conversation)
           .where(
             account_id: current_account.id,
             conversation_id: conversation_ids,
             message_type: Message.message_types[:incoming],
             private: false
           )
           .exists?(['messages.created_at > COALESCE(conversations.agent_last_seen_at, ?)', Time.zone.at(0)])
  end

  def mark_read_required?
    communication_thread.unread_count.positive? || unread_messages_exist? || unread_notifications_exist?
  end

  def unread_notifications_exist?
    current_user.notifications.exists?(
      account_id: current_account.id,
      primary_actor_type: 'Conversation',
      primary_actor_id: conversations.map(&:id),
      read_at: nil
    )
  end

  def refresh_communication_thread!
    latest_accessible_conversation&.refresh_communication_thread!
  end

  def latest_accessible_conversation
    conversations.max_by { |conversation| [conversation.last_activity_at || conversation.updated_at, conversation.id] }
  end

  def enqueue_realtime_update(updated_thread)
    source_conversation = latest_accessible_conversation
    return if source_conversation.blank?

    CommunicationThreads::RealtimeUpdateJob.perform_later(
      communication_thread_id: updated_thread.id,
      source_conversation_id: source_conversation.id,
      source_event: 'conversation.read',
      performer_id: current_user.id
    )
  end
end
