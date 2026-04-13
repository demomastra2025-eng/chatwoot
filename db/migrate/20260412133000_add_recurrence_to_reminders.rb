class AddRecurrenceToReminders < ActiveRecord::Migration[7.0]
  def change
    add_column :reminders, :repeat_mode, :integer, default: 0, null: false
    add_column :reminders, :repeat_until_at, :datetime

    add_index :reminders, [:account_id, :repeat_mode, :scheduled_at], name: 'idx_reminders_on_account_repeat_scheduled'
  end
end
