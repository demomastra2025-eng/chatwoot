class AddCampaignRunIdToCampaignDeliveries < ActiveRecord::Migration[7.0]
  def change
    add_reference :campaign_deliveries, :campaign_run, foreign_key: true
  end
end
