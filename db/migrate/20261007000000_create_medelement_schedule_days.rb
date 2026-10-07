class CreateMedelementScheduleDays < ActiveRecord::Migration[7.2]
  def change
    create_table :medelement_schedule_days do |t|
      t.references :account, null: false
      t.references :hook, null: false
      t.references :resource, null: false
      t.string :specialist_code, null: false
      t.date :date, null: false
      t.jsonb :windows, null: false, default: []
      t.string :status, null: false, default: 'unverified'
      t.integer :consecutive_empty_count, null: false, default: 0
      t.datetime :source_checked_at
      t.datetime :last_attempted_at
      t.string :raw_digest
      t.timestamps
    end

    add_index :medelement_schedule_days, %i[hook_id specialist_code date],
              unique: true, name: 'idx_medelement_schedule_days_provider_day'
    add_index :medelement_schedule_days, %i[account_id resource_id date],
              name: 'idx_medelement_schedule_days_resource_date'
  end
end
