class ScopeCampaignDeliveryUniquenessToCampaignRun < ActiveRecord::Migration[7.0]
  def change
    remove_index :campaign_deliveries, column: [:campaign_id, :contact_id],
                                     name: 'index_campaign_deliveries_on_campaign_id_and_contact_id'

    add_index :campaign_deliveries, [:campaign_id, :contact_id],
              name: 'index_campaign_deliveries_on_campaign_id_and_contact_id'

    add_index :campaign_deliveries, [:campaign_run_id, :contact_id],
              unique: true,
              where: 'campaign_run_id IS NOT NULL',
              name: 'index_campaign_deliveries_on_campaign_run_id_and_contact_id'
  end
end
