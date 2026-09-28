class IndexRemindersForCaptainReceiptRecovery < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  INDEX_NAME = 'idx_reminders_captain_unfinished_delivery'.freeze
  PREDICATE = <<~SQL.squish.freeze
    status IN (2, 3) AND
    metadata ->> 'processing_claim_token' IS NOT NULL AND
    metadata ->> 'delivery_materialized_message_id' IS NOT NULL AND
    (metadata ->> 'delivery_dispatched_message_id') IS DISTINCT FROM (metadata ->> 'delivery_materialized_message_id')
  SQL

  def change
    add_index :reminders, :id, name: INDEX_NAME, where: PREDICATE, algorithm: :concurrently
  end
end
