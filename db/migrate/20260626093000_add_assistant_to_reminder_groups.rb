class AddAssistantToReminderGroups < ActiveRecord::Migration[7.0]
  def change
    add_reference :reminder_groups,
                  :assistant,
                  foreign_key: { to_table: :captain_assistants },
                  index: true
  end
end
