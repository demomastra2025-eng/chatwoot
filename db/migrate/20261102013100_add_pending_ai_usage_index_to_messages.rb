class AddPendingAiUsageIndexToMessages < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    valid = select_value("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass('idx_messages_pending_ai_usage')")
    remove_index :messages, name: 'idx_messages_pending_ai_usage', algorithm: :concurrently if valid == false
    add_index :messages, [:ai_usage_retry_at, :id], where: 'ai_usage_pending = true', name: 'idx_messages_pending_ai_usage', algorithm: :concurrently,
                                                    if_not_exists: true
  end

  def down
    remove_index :messages, name: 'idx_messages_pending_ai_usage', algorithm: :concurrently, if_exists: true
  end
end
