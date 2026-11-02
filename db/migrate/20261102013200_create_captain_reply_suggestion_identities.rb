class CreateCaptainReplySuggestionIdentities < ActiveRecord::Migration[7.1]
  def change
    reversible { |direction| direction.up { execute "SET LOCAL lock_timeout = '5s'" } }
    create_table :captain_reply_suggestion_identities do |t|
      t.string :request_id, null: false
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :conversation, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.datetime :generated_at, null: false
      t.timestamps
    end
    add_index :captain_reply_suggestion_identities, :request_id, unique: true, name: 'idx_reply_suggestion_identity_request'
    add_index :captain_reply_suggestion_identities, :conversation_id, name: 'idx_reply_suggestion_identity_conversation'
  end
end
