class Conversations::SharedUnreadStateBatchPreloader
  def initialize(account:, conversation_ids:)
    @account = account
    @conversation_ids = Array(conversation_ids).map(&:to_i).uniq
    @last_seen_timestamps = nil
    @unread_counts = nil
  end

  def perform
    return self if conversation_ids.empty?

    preload_last_seen_timestamps
    preload_unread_counts
    self
  end

  def last_seen_timestamps
    @last_seen_timestamps
  end

  def unread_counts
    @unread_counts
  end

  private

  attr_reader :account, :conversation_ids

  def preload_last_seen_timestamps
    @last_seen_timestamps = Conversation
                            .where(account_id: account.id, id: conversation_ids)
                            .pluck(:id, :agent_last_seen_at)
                            .to_h
  end

  def preload_unread_counts
    @unread_counts = unread_count_scope.group('messages.conversation_id').count
  end

  def unread_count_scope
    Message.without_imported_history.reorder(nil)
           .incoming
           .where(account_id: account.id, conversation_id: conversation_ids, private: false)
           .joins(:conversation)
           .where("messages.created_at > COALESCE(conversations.agent_last_seen_at, '-infinity'::timestamp)")
  end
end
