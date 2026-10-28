class AdoptLegacyAppointmentNotificationRules < ActiveRecord::Migration[7.1]
  def up
    return unless column_exists?(:automation_rules, :calendar_managed)

    execute(<<~SQL.squish)
      UPDATE automation_rules
      SET calendar_managed = TRUE
      WHERE calendar_managed = FALSE
        AND event_name IN ('appointment_created', 'appointment_updated', 'appointment_rescheduled', 'appointment_cancelled', 'appointment_completed', 'appointment_no_show')
        AND EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(actions, '[]'::jsonb)) AS action_elem
          WHERE action_elem ->> 'action_name' = 'create_touch'
        )
    SQL
  end

  def down
    # One-way data normalization
  end
end
