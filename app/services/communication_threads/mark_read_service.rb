class CommunicationThreads::MarkReadService
  attr_reader :last_seen_at, :read_state_changed, :sidebar_counts_refresh_required

  def initialize(communication_thread:, current_user:, current_account:, accessible_links:)
    @communication_thread = communication_thread
    @current_user = current_user
    @current_account = current_account
    @accessible_links = accessible_links
  end

  def perform
    return communication_thread unless change_or_repair_required?

    mark_read_state! if read_state_changed

    refresh_communication_thread!
    updated_thread = communication_thread.reload
    @sidebar_counts_refresh_required ||= aggregate_unread_cleared?(updated_thread)
    @last_seen_at = conversations.filter_map { |conversation| conversation.last_seen_at_for(current_user) }.max
    enqueue_realtime_update(updated_thread)
    updated_thread
  end

  def channel_read_states
    unread_counts = current_channel_unread_counts
    conversations.map do |conversation|
      {
        conversation_id: conversation.display_id,
        agent_last_seen_at: conversation.last_seen_at_for(current_user)&.to_i,
        unread_count: unread_counts.fetch(conversation.id, 0)
      }
    end
  end

  private

  attr_reader :communication_thread, :current_user, :current_account, :accessible_links, :aggregate_was_unread

  def change_or_repair_required?
    unread_messages_changed = unread_messages_exist?
    @aggregate_was_unread = communication_thread.unread_count.positive?
    @read_state_changed = unread_messages_changed || unread_notifications_exist?
    @sidebar_counts_refresh_required = unread_messages_changed
    read_state_changed || aggregate_was_unread
  end

  def aggregate_unread_cleared?(updated_thread)
    aggregate_was_unread && updated_thread.unread_count.zero?
  end

  def mark_read_state!
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
        refresh_communication_thread: false,
        broadcast_read_state: false
      ).perform
    end
  end

  def conversations
    @conversations ||= begin
      links = accessible_links.respond_to?(:includes) ? accessible_links.includes(:conversation) : accessible_links
      links.filter_map(&:conversation)
    end
  end

  def unread_messages_exist?
    @initial_unread_counts = load_channel_unread_counts
    @initial_unread_counts.present?
  end

  def current_channel_unread_counts
    return @initial_unread_counts if !read_state_changed && defined?(@initial_unread_counts)

    load_channel_unread_counts
  end

  def load_channel_unread_counts
    conversation_ids = conversations.map(&:id)
    return {} if conversation_ids.blank?

    Conversations::SharedUnreadStatePreloader.new(
      account: current_account,
      conversation_ids: conversation_ids
    ).perform.unread_counts
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
    source_conversation = latest_accessible_conversation
    return if source_conversation.blank?

    Conversations::LastSeenUpdater.new(conversation: source_conversation).refresh_communication_thread!
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
