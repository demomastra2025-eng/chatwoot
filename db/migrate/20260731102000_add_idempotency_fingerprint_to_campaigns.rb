class AddIdempotencyFingerprintToCampaigns < ActiveRecord::Migration[7.0]
  def change
    add_column :campaigns, :idempotency_fingerprint, :string
  end
end
