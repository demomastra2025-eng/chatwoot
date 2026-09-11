class Conversations::UserReadStateBatchPreloader
  def initialize(account:, conversation_ids:, users:)
    @account = account
    @conversation_ids = Array(conversation_ids).map(&:to_i).uniq
    @user_ids = Array(users).map(&:id).map(&:to_i).uniq
    @last_seen_timestamps = {}
    @unread_counts = {}
  end

  def perform
    return self if conversation_ids.empty? || user_ids.empty?

    preload_last_seen_timestamps
    preload_unread_counts
    self
  end

  def last_seen_timestamps_for(user)
    last_seen_timestamps.fetch(user.id, {})
  end

  def unread_counts_for(user)
    unread_counts.fetch(user.id, {})
  end

  private

  attr_reader :account, :conversation_ids, :user_ids, :last_seen_timestamps, :unread_counts

  def preload_last_seen_timestamps
    ConversationUserReadState
      .where(account_id: account.id, conversation_id: conversation_ids, user_id: user_ids)
      .pluck(:user_id, :conversation_id, :last_seen_at)
      .each { |user_id, conversation_id, timestamp| (last_seen_timestamps[user_id] ||= {})[conversation_id] = timestamp }
  end

  def preload_unread_counts
    unread_count_scope.group('read_users.user_id', 'messages.conversation_id').count.each do |key, count|
      user_id, conversation_id = key
      (unread_counts[user_id] ||= {})[conversation_id] = count
    end
  end

  def unread_count_scope
    Message.without_imported_history.reorder(nil)
           .incoming
           .where(account_id: account.id, conversation_id: conversation_ids, private: false)
           .joins(:conversation)
           .joins(read_users_join)
           .joins(read_states_join)
           .where('messages.created_at > COALESCE(read_states.last_seen_at, conversations.agent_last_seen_at, ?)', Time.at(0).utc)
  end

  def read_users_join
    ApplicationRecord.sanitize_sql_array([
                                           'INNER JOIN account_users read_users ON read_users.account_id = conversations.account_id ' \
                                           'AND read_users.user_id IN (?)',
                                           user_ids
                                         ])
  end

  def read_states_join
    'LEFT JOIN conversation_user_read_states read_states ON read_states.conversation_id = conversations.id ' \
      'AND read_states.user_id = read_users.user_id'
  end
end
