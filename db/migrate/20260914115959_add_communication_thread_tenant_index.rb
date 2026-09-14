class AddCommunicationThreadTenantIndex < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = 'idx_communication_threads_account_id'.freeze

  def up
    add_index :communication_threads,
              [:account_id, :id],
              unique: true,
              algorithm: :concurrently,
              if_not_exists: true,
              name: INDEX_NAME
  end

  def down
    remove_index :communication_threads,
                 name: INDEX_NAME,
                 algorithm: :concurrently,
                 if_exists: true
  end
end
