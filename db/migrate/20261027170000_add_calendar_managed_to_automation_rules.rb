class AddCalendarManagedToAutomationRules < ActiveRecord::Migration[7.2]
  def change
    add_column :automation_rules, :calendar_managed, :boolean, default: false, null: false
    add_index :automation_rules, [:account_id, :calendar_managed], name: 'index_automation_rules_on_account_and_calendar_managed'
  end
end
