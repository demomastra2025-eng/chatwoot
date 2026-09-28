class IndexCaptainDeferredCloudMessagesForReplay < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  INDEX_NAME = 'idx_messages_captain_deferred_cloud_replay'.freeze

  def change
    # The minute scanner must not scan all historical Captain messages.
    # The channel/provider and due-at checks happen after this small DB subset.
    add_index :messages, :id,
              name: INDEX_NAME,
              where: "(additional_attributes ->> 'captain_delivery_state') = 'deferred'",
              algorithm: :concurrently
  end
end
