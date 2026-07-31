class AddIdempotencyAndLaunchLeaseToCampaigns < ActiveRecord::Migration[7.0]
  def change
    add_column :campaigns, :idempotency_key, :string
    add_column :campaigns, :launch_requested_at, :datetime

    add_index :campaigns,
              [:account_id, :idempotency_key],
              unique: true,
              where: 'idempotency_key IS NOT NULL',
              name: 'index_campaigns_on_account_id_and_idempotency_key'
    add_index :campaigns, :launch_requested_at
  end
end
