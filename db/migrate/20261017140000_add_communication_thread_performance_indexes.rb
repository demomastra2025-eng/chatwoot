class AddCommunicationThreadPerformanceIndexes < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :communication_thread_conversations,
              [:account_id, :communication_thread_id, :conversation_id],
              name: 'idx_ctc_account_thread_conversation',
              algorithm: :concurrently,
              if_not_exists: true

    add_index :communication_threads,
              [:account_id, :status, :assignee_id],
              name: 'idx_communication_threads_account_status_assignee',
              algorithm: :concurrently,
              if_not_exists: true
  end
end
