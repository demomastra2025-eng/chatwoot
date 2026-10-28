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

    execute(<<~SQL.squish)
      WITH candidate_presets AS (
        SELECT
          id,
          account_id,
          CASE
            WHEN event_name = 'appointment_created'
              AND COALESCE(actions -> 0 -> 'action_params' -> 0 ->> 'relative_anchor', actions -> 0 -> 'action_params' ->> 'relative_anchor') = 'touch.created_at'
              AND COALESCE((actions -> 0 -> 'action_params' -> 0 ->> 'relative_offset_seconds')::int, (actions -> 0 -> 'action_params' ->> 'relative_offset_seconds')::int, 0) IN (0, 60)
              THEN 'appointment_created'
            WHEN event_name = 'appointment_rescheduled'
              AND COALESCE(actions -> 0 -> 'action_params' -> 0 ->> 'relative_anchor', actions -> 0 -> 'action_params' ->> 'relative_anchor') = 'touch.created_at'
              THEN 'appointment_rescheduled'
            WHEN event_name = 'appointment_cancelled'
              AND COALESCE(actions -> 0 -> 'action_params' -> 0 ->> 'relative_anchor', actions -> 0 -> 'action_params' ->> 'relative_anchor') = 'touch.created_at'
              THEN 'appointment_cancelled'
            WHEN event_name = 'appointment_created'
              AND COALESCE(actions -> 0 -> 'action_params' -> 0 ->> 'relative_anchor', actions -> 0 -> 'action_params' ->> 'relative_anchor') = 'appointment.starts_at'
              AND COALESCE((actions -> 0 -> 'action_params' -> 0 ->> 'relative_offset_seconds')::int, (actions -> 0 -> 'action_params' ->> 'relative_offset_seconds')::int) = -86400
              THEN 'appointment_day_before'
            WHEN event_name = 'appointment_created'
              AND COALESCE(actions -> 0 -> 'action_params' -> 0 ->> 'relative_anchor', actions -> 0 -> 'action_params' ->> 'relative_anchor') = 'appointment.starts_at'
              AND COALESCE((actions -> 0 -> 'action_params' -> 0 ->> 'relative_offset_seconds')::int, (actions -> 0 -> 'action_params' ->> 'relative_offset_seconds')::int) = -7200
              THEN 'appointment_two_hours_before'
            WHEN event_name = 'appointment_completed'
              AND COALESCE(actions -> 0 -> 'action_params' -> 0 ->> 'relative_anchor', actions -> 0 -> 'action_params' ->> 'relative_anchor') = 'appointment.ends_at'
              THEN 'appointment_review_request'
            ELSE NULL
          END AS preset_key
        FROM automation_rules
        WHERE calendar_managed = TRUE
          AND COALESCE(description, '') NOT LIKE '%[scheduling_preset:%'
      ),
      ranked AS (
        SELECT
          id,
          preset_key,
          ROW_NUMBER() OVER (PARTITION BY account_id, preset_key ORDER BY id ASC) AS rn
        FROM candidate_presets
        WHERE preset_key IS NOT NULL
      )
      UPDATE automation_rules ar
      SET description = TRIM(CONCAT(COALESCE(ar.description, ''), ' [scheduling_preset:', ranked.preset_key, ']'))
      FROM ranked
      WHERE ar.id = ranked.id
        AND ranked.rn = 1
    SQL
  end

  def down
    # One-way data normalization
  end
end
