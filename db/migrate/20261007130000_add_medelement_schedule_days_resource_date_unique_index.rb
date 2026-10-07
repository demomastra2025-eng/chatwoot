class AddMedelementScheduleDaysResourceDateUniqueIndex < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_index :medelement_schedule_days, %i[hook_id resource_id date],
              unique: true, name: 'idx_medelement_schedule_days_hook_resource_date', algorithm: :concurrently
  end
end
