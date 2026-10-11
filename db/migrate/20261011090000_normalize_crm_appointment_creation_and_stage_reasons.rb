class NormalizeCrmAppointmentCreationAndStageReasons < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  BATCH_SIZE = 5_000

  def up
    each_id_range(:crm_pipelines) { |low, high| normalize_appointment_creation(low, high) }
    each_id_range(:crm_stages) { |low, high| clear_stage_reasons(low, high) }
    each_id_range(:crm_pipelines) { |low, high| clear_rule_reasons(low, high) }
    each_id_range(:crm_events) { |low, high| clear_event_transition_reasons(low, high) }
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Removed ordinary stage reasons cannot be reconstructed; CRM loss history is retained.'
  end

  private

  def each_id_range(table)
    last_id = 0
    loop do
      ids = select_values("SELECT id FROM #{quote_table_name(table)} WHERE id > #{last_id} ORDER BY id LIMIT #{BATCH_SIZE}").map(&:to_i)
      break if ids.empty?

      yield ids.first, ids.last
      last_id = ids.last
    end
  end

  def normalize_appointment_creation(low, high)
    # Preserve explicit legacy source opt-ins. Incoming-channel creation never
    # enables appointment creation, and an explicit master OFF stays OFF.
    execute <<~SQL.squish
      UPDATE crm_pipelines
      SET appointment_automation = jsonb_set(
        appointment_automation, '{auto_create_deals}',
        to_jsonb(
          COALESCE(appointment_automation -> 'auto_create_from_calendar' = 'true'::jsonb, FALSE)
          OR COALESCE(appointment_automation -> 'auto_create_from_medelement' = 'true'::jsonb, FALSE)
        )
      )
      WHERE jsonb_typeof(appointment_automation) = 'object'
        AND NOT appointment_automation ? 'auto_create_deals'
        AND id BETWEEN #{low} AND #{high}
    SQL

  end

  def clear_stage_reasons(low, high)
    execute <<~SQL.squish
      UPDATE crm_stages
      SET transition_reason_options = '[]'::jsonb, transition_reason_required = FALSE
      WHERE (transition_reason_options <> '[]'::jsonb OR transition_reason_required = TRUE)
        AND id BETWEEN #{low} AND #{high}
    SQL

    execute <<~SQL.squish
      UPDATE crm_stages
      SET closing_reason_options = '[]'::jsonb, closing_reason_required = FALSE
      WHERE outcome <> 'lost' AND (closing_reason_options <> '[]'::jsonb OR closing_reason_required = TRUE)
        AND id BETWEEN #{low} AND #{high}
    SQL
  end

  def clear_rule_reasons(low, high)
    execute <<~SQL.squish
      UPDATE crm_pipelines AS pipeline
      SET appointment_automation = jsonb_set(
        pipeline.appointment_automation, '{rules}',
        (
          SELECT COALESCE(jsonb_agg(
            CASE
              WHEN jsonb_typeof(rule) <> 'object' THEN rule
              WHEN EXISTS (
                SELECT 1 FROM crm_stages AS stage
                WHERE stage.pipeline_id = pipeline.id AND stage.id::text = rule ->> 'stage_id' AND stage.outcome <> 'lost'
              ) THEN rule - 'transition_reason' - 'closing_reasons'
              ELSE rule - 'transition_reason'
            END
            ORDER BY ordinal
          ), '[]'::jsonb)
          FROM jsonb_array_elements(pipeline.appointment_automation -> 'rules') WITH ORDINALITY AS rules(rule, ordinal)
        )
      )
      WHERE jsonb_typeof(pipeline.appointment_automation -> 'rules') = 'array'
        AND pipeline.id BETWEEN #{low} AND #{high}
    SQL
  end

  def clear_event_transition_reasons(low, high)
    # Event envelopes, actors, loss reasons, notes and timestamps stay intact.
    execute <<~SQL.squish
      UPDATE crm_events SET meta = meta - 'transition_reason'
      WHERE meta ? 'transition_reason'
        AND id BETWEEN #{low} AND #{high}
    SQL
  end
end
