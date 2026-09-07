class AddAllDayToCrmTasks < ActiveRecord::Migration[7.0]
  def change
    add_column :crm_tasks, :all_day, :boolean, default: false, null: false
  end
end
