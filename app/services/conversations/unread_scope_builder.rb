class Conversations::UnreadScopeBuilder
  UNREAD_EXISTS_SQL = <<~SQL.squish
    EXISTS (
      SELECT 1
      FROM messages unread_messages
      WHERE unread_messages.conversation_id = conversations.id
        AND unread_messages.account_id = :account_id
        AND unread_messages.message_type = :incoming_message_type
        AND unread_messages.private = FALSE
        AND #{Message.not_imported_history_sql('unread_messages')}
        AND unread_messages.created_at > COALESCE(
          (
            SELECT COALESCE(conversation_user_read_states.last_seen_at, '-infinity'::timestamp)
            FROM conversation_user_read_states
            WHERE conversation_user_read_states.conversation_id = conversations.id
              AND conversation_user_read_states.user_id = :user_id
          ),
          conversations.agent_last_seen_at,
          '-infinity'::timestamp
        )
    )
  SQL

  def initialize(scope:, account:, user:)
    @scope = scope
    @account = account
    @user = user
  end

  def perform
    scope.where(
      UNREAD_EXISTS_SQL,
      account_id: account.id,
      user_id: user.id,
      incoming_message_type: Message.message_types[:incoming]
    )
  end

  private

  attr_reader :scope, :account, :user
end
