class Conversations::SharedUnreadStatePreloader
  attr_reader :last_seen_timestamps, :unread_counts

  def initialize(account:, conversation_ids:)
    @account = account
    @conversation_ids = Array(conversation_ids).map(&:to_i).uniq
    @last_seen_timestamps = {}
    @unread_counts = {}
  end

  def perform
    return self if conversation_ids.empty?

    @last_seen_timestamps = Conversation
                            .where(account_id: account.id, id: conversation_ids)
                            .pluck(:id, :agent_last_seen_at)
                            .to_h
    @unread_counts = Message.without_imported_history.reorder(nil)
                            .incoming
                            .where(account_id: account.id, conversation_id: conversation_ids, private: false)
                            .joins(:conversation)
                            .where(shared_cursor_condition)
                            .group(:conversation_id)
                            .count
    self
  end

  private

  attr_reader :account, :conversation_ids

  def shared_cursor_condition
    "messages.created_at > COALESCE(conversations.agent_last_seen_at, '-infinity'::timestamp)"
  end
end
