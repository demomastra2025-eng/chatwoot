class CreateConfirmationRequests < ActiveRecord::Migration[7.1]
  def change
    create_table :confirmation_requests do |t|
      t.references :account, null: false, foreign_key: true
      t.references :conversation, foreign_key: true
      t.references :contact, foreign_key: true
      t.references :inbox, foreign_key: true
      t.references :requested_by, foreign_key: { to_table: :users }
      t.references :resolved_by, foreign_key: { to_table: :users }
      t.references :resolved_message, foreign_key: { to_table: :messages }
      t.references :delivery_message, foreign_key: { to_table: :messages }
      t.string :subject_type
      t.bigint :subject_id
      t.string :status, null: false, default: 'pending'
      t.string :token, null: false
      t.string :delivery_strategy
      t.string :title, null: false
      t.text :body, null: false
      t.datetime :expires_at
      t.datetime :resolved_at
      t.string :resolution_source
      t.float :resolution_confidence
      t.jsonb :metadata, null: false, default: {}
      t.jsonb :resolution_metadata, null: false, default: {}
      t.string :idempotency_key

      t.timestamps
    end

    add_index :confirmation_requests, :token, unique: true
    add_index :confirmation_requests, [:account_id, :idempotency_key], unique: true, where: 'idempotency_key IS NOT NULL'
    add_index :confirmation_requests, [:account_id, :status, :conversation_id]
    add_index :confirmation_requests, [:account_id, :subject_type, :subject_id], name: 'idx_confirmation_requests_on_account_subject'
  end
end
