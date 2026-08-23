class CreateWhatsappWebhookRoutes < ActiveRecord::Migration[7.1]
  def change
    create_table :whatsapp_webhook_routes do |t|
      t.string :waba_id, null: false
      t.string :phone_number_id, null: false
      t.string :destination, null: false
      t.timestamps
    end

    add_index :whatsapp_webhook_routes, [:waba_id, :phone_number_id, :destination],
              unique: true, name: 'idx_whatsapp_webhook_routes_exact'
    add_index :whatsapp_webhook_routes, :waba_id,
              name: 'idx_whatsapp_webhook_routes_waba'
    add_check_constraint :whatsapp_webhook_routes, "waba_id ~ '^[0-9]+$'",
                         name: 'chk_whatsapp_webhook_routes_waba_digits'
    add_check_constraint :whatsapp_webhook_routes, "phone_number_id ~ '^[0-9]+$'",
                         name: 'chk_whatsapp_webhook_routes_phone_digits'
    add_check_constraint :whatsapp_webhook_routes, "destination IN ('dev', 'widget')",
                         name: 'chk_whatsapp_webhook_routes_destination'
  end
end
