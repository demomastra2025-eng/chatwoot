class AddExecutionScheduleToAutomationRules < ActiveRecord::Migration[7.1]
  def change
    add_column :automation_rules, :execution_schedule, :jsonb, default: {}, null: false
  end
end
