class CreateAccountAiUsageEvents < ActiveRecord::Migration[7.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"
    add_message_columns
    create_dialog_states
    create_usage_events
    create_rollout
  end

  def down
    drop_table :account_ai_usage_rollouts, if_exists: true
    drop_table :account_ai_usage_events
    drop_table :account_ai_dialog_states, if_exists: true
    remove_column :messages, :ai_usage_pending, if_exists: true
    remove_column :messages, :ai_usage_version, if_exists: true
    remove_column :messages, :ai_usage_retry_at, if_exists: true
    remove_column :messages, :ai_usage_sent_at
  end

  private

  def add_message_columns
    # Keep this DDL transaction short. Historical source preparation is an explicit,
    # batched operational task after commit, never part of the messages table lock.
    add_column :messages, :ai_usage_sent_at, :datetime
    add_column :messages, :ai_usage_version, :integer
    add_column :messages, :ai_usage_retry_at, :datetime
    add_column :messages, :ai_usage_pending, :boolean, null: false, default: false
  end

  def create_dialog_states
    create_table :account_ai_dialog_states do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :contact, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.jsonb :state, null: false, default: {}
      t.timestamps
    end
    add_index :account_ai_dialog_states, [:account_id, :contact_id], unique: true
  end

  def create_usage_events
    create_table :account_ai_usage_events do |t|
      t.references :contact, foreign_key: { on_delete: :nullify }, index: false
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :event_key, null: false
      t.string :bucket, null: false
      t.datetime :occurred_at, null: false
      t.integer :quantity, null: false
      t.timestamps
    end
    add_index :account_ai_usage_events, [:account_id, :event_key], unique: true
    add_index :account_ai_usage_events, [:account_id, :contact_id, :occurred_at], name: 'idx_ai_usage_events_contact_time'
  end

  def create_rollout
    create_table :account_ai_usage_rollouts do |t|
      t.string :name, null: false
      t.bigint :cutoff_message_id
      t.bigint :cursor, null: false, default: 0
      t.datetime :prepared_at
      t.datetime :activated_at
      t.timestamps
    end
    add_index :account_ai_usage_rollouts, :name, unique: true
  end
end
