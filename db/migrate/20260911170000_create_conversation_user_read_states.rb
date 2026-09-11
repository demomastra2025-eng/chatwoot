class CreateConversationUserReadStates < ActiveRecord::Migration[7.1]
  BACKFILL_SQL = <<~SQL.squish.freeze
    INSERT INTO conversation_user_read_states
      (account_id, conversation_id, user_id, last_seen_at, created_at, updated_at)
    SELECT conversations.account_id,
           conversations.id,
           account_users.user_id,
           conversations.agent_last_seen_at,
           CURRENT_TIMESTAMP,
           CURRENT_TIMESTAMP
    FROM conversations
    INNER JOIN account_users ON account_users.account_id = conversations.account_id
    ON CONFLICT (conversation_id, user_id) DO NOTHING
  SQL

  def change
    create_table :conversation_user_read_states do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :conversation, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :last_seen_at
      t.timestamps
    end

    add_index :conversation_user_read_states,
              [:conversation_id, :user_id],
              unique: true,
              name: 'idx_conversation_user_read_states_unique'
    add_index :conversation_user_read_states, [:account_id, :user_id]

    reversible do |direction|
      direction.up { execute BACKFILL_SQL }
    end
  end
end
