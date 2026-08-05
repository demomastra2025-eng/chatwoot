class AddAppointmentConfirmationResponseToReminders < ActiveRecord::Migration[7.1]
  SUPPORTED_RESPONSE_ACTION_CHECK = <<~SQL.squish.freeze
    (response_action IS NULL AND response_button_index IS NULL) OR (
      response_action = 'confirm_appointment' AND
      response_button_index = 0 AND
      action_type = 0 AND
      content_kind = 1 AND
      repeat_mode = 0 AND
      remindable_type = 'Scheduling::Appointment' AND
      remindable_id IS NOT NULL
    )
  SQL

  def change
    add_column :reminders, :response_action, :string
    add_column :reminders, :response_button_index, :integer
    add_check_constraint :reminders,
                         SUPPORTED_RESPONSE_ACTION_CHECK,
                         name: 'reminders_response_action_supported'

    add_reference :confirmation_requests,
                  :reminder,
                  foreign_key: true,
                  index: { unique: true }
  end
end
