class Conversations::UserReadStatePreloader
  attr_reader :last_seen_timestamps, :unread_counts

  def initialize(account:, conversation_ids:, user:)
    @account = account
    @conversation_ids = Array(conversation_ids).map(&:to_i).uniq
    @user = user
    @last_seen_timestamps = {}
    @unread_counts = {}
  end

  def perform
    return self if conversation_ids.empty?

    @last_seen_timestamps = ConversationUserReadState
                            .where(conversation_id: conversation_ids, user_id: user.id)
                            .pluck(:conversation_id, :last_seen_at)
                            .to_h
    @unread_counts = Message.without_imported_history.reorder(nil)
                            .incoming
                            .where(account_id: account.id, conversation_id: conversation_ids, private: false)
                            .joins(:conversation)
                            .where(user_cursor_condition, user.id)
                            .group(:conversation_id)
                            .count
    self
  end

  private

  attr_reader :account, :conversation_ids, :user

  def user_cursor_condition
    'messages.created_at > COALESCE(' \
      "(SELECT COALESCE(last_seen_at, '-infinity'::timestamp) FROM conversation_user_read_states " \
      'WHERE conversation_id = conversations.id AND user_id = ?), ' \
      "conversations.agent_last_seen_at, '-infinity'::timestamp)"
  end
end
