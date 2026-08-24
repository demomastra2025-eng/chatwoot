class AddRegistrationTokenToWhatsappWebhookRoutes < ActiveRecord::Migration[7.1]
  def change
    add_column :whatsapp_webhook_routes, :registration_token, :string, limit: 36
  end
end
