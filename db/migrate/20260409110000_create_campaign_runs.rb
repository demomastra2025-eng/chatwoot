class CreateCampaignRuns < ActiveRecord::Migration[7.0]
  def change
    create_table :campaign_runs do |t|
      t.references :account, null: false, foreign_key: true
      t.references :campaign, null: false, foreign_key: true
      t.references :inbox, null: false, foreign_key: true
      t.integer :status, null: false, default: 0
      t.integer :total_count, null: false, default: 0
      t.integer :processed_count, null: false, default: 0
      t.integer :successful_count, null: false, default: 0
      t.integer :failed_count, null: false, default: 0
      t.integer :skipped_count, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.datetime :started_at
      t.datetime :completed_at
      t.text :error_message

      t.timestamps
    end

    add_index :campaign_runs, [:campaign_id, :created_at]
    add_index :campaign_runs, [:account_id, :created_at]
  end
end
