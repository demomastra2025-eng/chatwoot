class AddRecipientCountryToWhatsappUsageDeliveries < ActiveRecord::Migration[7.1]
  def change
    add_column :whatsapp_usage_deliveries, :recipient_country, :string, limit: 2
  end
end
