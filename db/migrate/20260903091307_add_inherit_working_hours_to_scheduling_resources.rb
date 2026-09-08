class AddInheritWorkingHoursToSchedulingResources < ActiveRecord::Migration[7.1]
  def change
    add_column :scheduling_resources, :inherit_working_hours_from_account, :boolean, default: false, null: false
  end
end
