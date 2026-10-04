-- Apply after the lifecycle migration to check legacy-row preservation and old writers.
DO $$
DECLARE
  old_writer_task_id BIGINT;
  old_writer_event_id BIGINT;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM crm_tasks
    WHERE id = 96000410
      AND outcome = 'cancelled'
      AND status_id = 96000402
      AND start_at = '2025-02-03 10:15:00+00'::timestamptz
      AND due_at = '2025-02-03 11:45:00+00'::timestamptz
      AND cancelled_at IS NULL
      AND all_day = FALSE
      AND due_on IS NULL
      AND schedule_timezone = 'Europe/Berlin'
      AND context_kind = 'personal'
  ) THEN
    RAISE EXCEPTION 'legacy timed task or explicit lifecycle mapping was changed';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM crm_task_types task_type
    JOIN crm_task_outcomes outcome ON outcome.task_type_id = task_type.id
    WHERE task_type.account_id = 96000400
      AND task_type.code = 'call'
      AND outcome.code = 'cancelled'
      AND outcome.task_type_id = task_type.id
      AND EXISTS (
        SELECT 1 FROM crm_tasks task
        WHERE task.id = 96000410
          AND task.task_type_id = task_type.id
          AND task.task_outcome_id = outcome.id
      )
  ) THEN
    RAISE EXCEPTION 'legacy task type/outcome compatibility mapping was not retained';
  END IF;

  IF (SELECT COUNT(*) FROM crm_stages WHERE pipeline_id = 96000403 AND outcome = 'won' AND active) <> 2
     OR (SELECT COUNT(*) FROM crm_stages WHERE pipeline_id = 96000403 AND outcome = 'lost' AND active) <> 2 THEN
    RAISE EXCEPTION 'duplicate active terminal stages were removed or rejected';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM crm_pipelines
    WHERE id = 96000403
      AND restrict_stage_skipping = FALSE
      AND restrict_backward_move = FALSE
      AND allow_stage_rule_override = FALSE
  ) THEN
    RAISE EXCEPTION 'legacy pipeline stage-entry restrictions were enabled by migration';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM crm_stage_visits
    WHERE deal_id = 96000409
      AND exited_at IS NULL
      AND estimated = TRUE
      AND entered_at = reliable_since
      AND stage_id = 96000404
  ) OR (SELECT COUNT(*) FROM crm_stage_visits WHERE deal_id = 96000409) <> 1 THEN
    RAISE EXCEPTION 'migration fabricated historical stage visits or lost the estimated current visit';
  END IF;

  INSERT INTO crm_tasks (account_id, status_id, title, activity_type, outcome, created_at, updated_at)
  VALUES (96000400, 96000402, 'Old writer task', 'task', 'completed', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
  RETURNING id INTO old_writer_task_id;

  IF NOT EXISTS (
    SELECT 1 FROM crm_tasks
    WHERE id = old_writer_task_id
      AND task_type_id IS NULL
      AND task_outcome_id IS NULL
      AND context_kind IS NULL
      AND all_day = FALSE
      AND due_on IS NULL
      AND schedule_timezone = 'Asia/Almaty'
      AND reschedule_count = 0
      AND position = 0
  ) THEN
    RAISE EXCEPTION 'old task writer insert did not receive safe compatibility defaults';
  END IF;

  INSERT INTO crm_events (account_id, eventable_type, eventable_id, event_type, meta, created_at)
  VALUES (96000400, 'Crm::Deal', 96000409, 'old_writer.event', '{}'::jsonb, CURRENT_TIMESTAMP)
  RETURNING id INTO old_writer_event_id;

  IF NOT EXISTS (
    SELECT 1 FROM crm_events
    WHERE id = old_writer_event_id
      AND correlation_id IS NOT NULL
      AND source = 'system'
      AND schema_version = 1
  ) THEN
    RAISE EXCEPTION 'old event writer insert did not receive required envelope defaults';
  END IF;
END $$;
