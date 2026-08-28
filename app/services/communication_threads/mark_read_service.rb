class CommunicationThreads::MarkReadService
  def initialize(communication_thread:, current_user:, current_account:, accessible_links:)
    @communication_thread = communication_thread
    @current_user = current_user
    @current_account = current_account
    @accessible_links = accessible_links
  end

  def perform
    conversations.each do |conversation|
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
    communication_thread.reload
  end

  private

  attr_reader :communication_thread, :current_user, :current_account, :accessible_links

  def conversations
    links = accessible_links
    links = links.includes(:conversation) if links.respond_to?(:includes)
    @conversations ||= links.filter_map(&:conversation)
  end

  def refresh_communication_thread!
    latest_accessible_conversation&.refresh_communication_thread!
  end

  def latest_accessible_conversation
    conversations.max_by { |conversation| [conversation.last_activity_at || conversation.updated_at, conversation.id] }
  end
end
