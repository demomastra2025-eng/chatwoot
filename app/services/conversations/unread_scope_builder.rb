class Conversations::UnreadScopeBuilder
  def initialize(scope:, account:)
    @scope = scope
    @account = account
  end

  def perform
    scope.where(
      <<~SQL.squish,
        EXISTS (
          SELECT 1
          FROM messages unread_messages
          WHERE unread_messages.conversation_id = conversations.id
            AND unread_messages.account_id = :account_id
            AND unread_messages.message_type = :incoming_message_type
            AND unread_messages.private = FALSE
            AND #{Message.not_imported_history_sql('unread_messages')}
            AND unread_messages.created_at > COALESCE(conversations.agent_last_seen_at, :epoch)
        )
      SQL
      account_id: account.id,
      incoming_message_type: Message.message_types[:incoming],
      epoch: Time.zone.at(0)
    )
  end

  private

  attr_reader :scope, :account
end
