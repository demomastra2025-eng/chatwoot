class IndexCaptainKnownDeliveryReceiptsForReplay < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  INDEX_NAME = 'idx_messages_captain_known_receipt_replay'.freeze

  def change
    # Only durable, provider-confirmed outcomes belong in the periodic scan;
    # ambiguous dispatches without a receipt must never be replayed.
    add_index :messages, :id,
              name: INDEX_NAME,
              where: <<~SQL.squish,
                ((additional_attributes ->> 'captain_delivery_state' = 'dispatching' AND source_id IS NOT NULL)
                 OR (additional_attributes ->> 'captain_delivery_state' = 'submitted'
                     AND additional_attributes -> 'captain_delivery_pending_ack' ->> 'status' = 'delivered')
                 OR (additional_attributes ->> 'captain_delivery_state' = 'provider_failed'
                     AND additional_attributes -> 'captain_delivery_pending_ack' ->> 'status' = 'failed'))
              SQL
              algorithm: :concurrently
  end
end
