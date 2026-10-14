class AddInheritWorkingHoursToSchedulingResources < ActiveRecord::Migration[7.2]
  def up
    return if column_exists?(:scheduling_resources, :inherit_working_hours_from_account)

    add_column :scheduling_resources, :inherit_working_hours_from_account,
               :boolean, default: false, null: false
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Existing specialist schedules must remain available'
  end
end
