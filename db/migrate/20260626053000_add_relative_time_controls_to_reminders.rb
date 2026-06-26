class AddRelativeTimeControlsToReminders < ActiveRecord::Migration[7.0]
  def change
    add_column :reminders, :relative_time_mode, :string, null: false, default: 'inherit_anchor_time'
    add_column :reminders, :relative_time_of_day, :string
    add_column :reminders, :manual_schedule_override, :boolean, null: false, default: false
    add_column :reminders, :schedule_revision, :integer, null: false, default: 0
    add_column :reminders, :last_materialized_anchor_at, :datetime
  end
end
