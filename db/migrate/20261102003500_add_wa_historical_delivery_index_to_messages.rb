# frozen_string_literal: true

class AddWaHistoricalDeliveryIndexToMessages < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = 'index_messages_on_acc_inbox_created_for_wa_deliveries'
  WHERE_CLAUSE = "message_type IN (1, 3) AND status IN (1, 2) AND private = false AND source_id IS NOT NULL AND source_id <> ''"

  def up
    add_index :messages,
              %i[account_id inbox_id created_at id updated_at],
              where: WHERE_CLAUSE,
              name: INDEX_NAME,
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    remove_index :messages,
                 name: INDEX_NAME,
                 algorithm: :concurrently,
                 if_exists: true
  end
end
