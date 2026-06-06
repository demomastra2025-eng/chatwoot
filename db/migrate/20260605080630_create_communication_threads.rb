class CreateCommunicationThreads < ActiveRecord::Migration[7.1]
  def up
    create_communication_threads
    create_communication_thread_conversations
  end

  def down
    drop_table :communication_thread_conversations
    drop_table :communication_threads
  end

  private

  def create_communication_threads
    create_table :communication_threads do |t|
      t.references :account, null: false, foreign_key: true
      t.references :contact, null: false, foreign_key: true
      t.bigint :display_id, null: false
      t.integer :status, null: false, default: 0
      t.integer :priority
      t.references :assignee, foreign_key: { to_table: :users }
      t.references :team, foreign_key: true
      t.datetime :last_activity_at
      t.integer :unread_count, null: false, default: 0
      t.timestamps
    end

    add_index :communication_threads, [:account_id, :display_id], unique: true, name: 'idx_communication_threads_account_display'
    add_index :communication_threads, [:account_id, :contact_id, :status], name: 'idx_communication_threads_account_contact_status'
    add_index :communication_threads, [:account_id, :last_activity_at], name: 'idx_communication_threads_account_activity'
  end

  def create_communication_thread_conversations
    create_table :communication_thread_conversations do |t|
      t.references :account, null: false, foreign_key: true
      t.references :communication_thread, null: false, foreign_key: true, index: { name: 'idx_ctc_on_thread_id' }
      t.references :conversation, null: false, foreign_key: true
      t.references :inbox, null: false, foreign_key: true
      t.references :contact_inbox, foreign_key: true
      t.boolean :primary, null: false, default: false
      t.timestamps
    end

    add_index :communication_thread_conversations,
              [:account_id, :conversation_id],
              unique: true,
              name: 'idx_ctc_account_conversation_unique'
    add_index :communication_thread_conversations,
              [:communication_thread_id, :inbox_id],
              name: 'idx_ctc_thread_inbox'
  end
end
