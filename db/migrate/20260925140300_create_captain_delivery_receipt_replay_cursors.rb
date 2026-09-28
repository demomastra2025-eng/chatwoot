class CreateCaptainDeliveryReceiptReplayCursors < ActiveRecord::Migration[7.2]
  def change
    create_table :captain_delivery_receipt_replay_cursors do |t|
      t.bigint :last_message_id, null: false, default: 0
      t.bigint :last_reminder_id, null: false, default: 0
      t.bigint :message_high_water_id, null: false, default: 0
      t.bigint :reminder_high_water_id, null: false, default: 0
      t.timestamps
    end
  end
end
