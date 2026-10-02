class CreateWhatsappUsageDeliveries < ActiveRecord::Migration[7.1]
  def change
    create_table :whatsapp_usage_deliveries do |t|
      t.integer :account_id, null: false
      t.string :phone_number, null: false
      t.text :provider_message_id, null: false
      t.integer :message_id
      t.integer :inbox_id
      t.datetime :delivered_at, precision: 6
      t.datetime :received_at, precision: 6, null: false
      t.string :category
      t.string :pricing_type
      t.string :pricing_model
      # Meta's explicit false is distinct from missing pricing metadata (nil).
      # rubocop:disable Rails/ThreeStateBooleanColumn
      t.boolean :billable
      # rubocop:enable Rails/ThreeStateBooleanColumn
      t.string :conversation_origin_type

      t.timestamps
    end

    add_delivery_indexes
    create_tracking_state
  end

  private

  def add_delivery_indexes
    add_index :whatsapp_usage_deliveries,
              %i[phone_number provider_message_id],
              unique: true,
              name: 'index_whatsapp_usage_deliveries_on_phone_and_provider_id'
    add_index :whatsapp_usage_deliveries,
              %i[account_id delivered_at],
              name: 'index_whatsapp_usage_deliveries_on_account_and_delivery_time'
    add_index :whatsapp_usage_deliveries,
              %i[account_id received_at],
              name: 'index_whatsapp_usage_deliveries_on_account_and_received_time'
    add_foreign_key :whatsapp_usage_deliveries, :accounts, on_delete: :cascade
  end

  def create_tracking_state
    create_table :whatsapp_usage_tracking_states do |t|
      t.datetime :tracking_started_at, precision: 6, null: false
      t.timestamps
    end

    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          INSERT INTO whatsapp_usage_tracking_states (tracking_started_at, created_at, updated_at)
          VALUES (CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        SQL
      end
    end
  end
end
