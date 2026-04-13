class CreateBulkActionRuns < ActiveRecord::Migration[7.0]
  def change
    create_table :bulk_action_runs do |t|
      t.references :account, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :resource_type, null: false
      t.string :action_name, null: false
      t.integer :status, null: false, default: 0
      t.integer :total_count, null: false, default: 0
      t.integer :processed_count, null: false, default: 0
      t.integer :failed_count, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}
      t.datetime :started_at
      t.datetime :completed_at
      t.text :error_message

      t.timestamps
    end

    add_index :bulk_action_runs, [:account_id, :resource_type, :created_at], name: 'idx_bulk_action_runs_on_account_resource_created'
    add_index :bulk_action_runs, [:account_id, :user_id, :created_at], name: 'idx_bulk_action_runs_on_account_user_created'
  end
end
