class CreateCampaignDeliveries < ActiveRecord::Migration[7.0]
  def change
    create_table :campaign_deliveries do |t|
      t.references :account, null: false, foreign_key: true
      t.references :campaign, null: false, foreign_key: true
      t.references :inbox, null: false, foreign_key: true
      t.references :contact, null: false, foreign_key: true
      t.integer :status, null: false, default: 0
      t.string :provider, null: false
      t.string :target_identifier
      t.string :provider_message_id
      t.text :error_message
      t.jsonb :metadata, null: false, default: {}
      t.datetime :last_status_at

      t.timestamps
    end

    add_index :campaign_deliveries, [:campaign_id, :contact_id], unique: true
    add_index :campaign_deliveries, :provider_message_id
  end
end
