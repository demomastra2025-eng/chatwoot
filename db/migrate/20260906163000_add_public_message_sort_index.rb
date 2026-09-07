class AddPublicMessageSortIndex < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    # Cover public, non-activity history without fetching every message body.
    # message_type=2 is the persisted activity enum value, not a mutable model lookup.
    add_index :messages, [:account_id, :conversation_id, :created_at],
              order: { created_at: :desc }, where: 'private = false AND message_type != 2',
              name: 'idx_messages_account_conversation_public_chat_time', algorithm: :concurrently
  end
end
