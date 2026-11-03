class CreateCaptainReplySuggestionIdentities < ActiveRecord::Migration[7.1]
  def up
    execute "SET LOCAL lock_timeout = '4s'"
    execute "SET LOCAL statement_timeout = '5s'"
    create_table :captain_reply_suggestion_identities do |t|
      t.string :request_id, null: false
      t.references :account, null: false, index: false
      t.references :conversation, null: false, index: false
      t.references :user, null: false, index: false
      t.datetime :generated_at, null: false
      t.timestamps
    end
    add_index :captain_reply_suggestion_identities, :request_id, unique: true, name: 'idx_reply_suggestion_identity_request'
    add_index :captain_reply_suggestion_identities, :conversation_id, name: 'idx_reply_suggestion_identity_conversation'
    add_validated_foreign_keys
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Retain AI history; rollback application source only.'
  end

  private

  def add_validated_foreign_keys
    add_foreign_key :captain_reply_suggestion_identities, :accounts, column: :account_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_reply_suggestion_identities, :accounts, column: :account_id
    add_foreign_key :captain_reply_suggestion_identities, :conversations, column: :conversation_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_reply_suggestion_identities, :conversations, column: :conversation_id
    add_foreign_key :captain_reply_suggestion_identities, :users, column: :user_id, on_delete: :cascade, validate: false
    validate_foreign_key :captain_reply_suggestion_identities, :users, column: :user_id
  end
end
