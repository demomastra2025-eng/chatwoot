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

  IF EXISTS (
    SELECT expected.task_id
    FROM (VALUES
      (96000440::bigint, 'Asia/Almaty'::text, 96000430::bigint),
      (96000441::bigint, 'Asia/Almaty'::text, 96000431::bigint),
      (96000442::bigint, 'Asia/Almaty'::text, 96000432::bigint),
      (96000443::bigint, 'Asia/Almaty'::text, 96000433::bigint),
      (96000444::bigint, 'Asia/Almaty'::text, 96000434::bigint),
      (96000445::bigint, 'America/New_York'::text, 96000435::bigint)
    ) AS expected(task_id, timezone, status_id)
    LEFT JOIN crm_tasks task ON task.id = expected.task_id
    WHERE task.id IS NULL
      OR task.schedule_timezone IS DISTINCT FROM expected.timezone
      OR task.status_id IS DISTINCT FROM expected.status_id
      OR task.outcome IS DISTINCT FROM 'completed'
      OR task.all_day IS DISTINCT FROM FALSE
      OR task.due_on IS NOT NULL
      OR task.start_at IS DISTINCT FROM '2025-02-03 10:15:00+00'::timestamptz
      OR task.due_at IS DISTINCT FROM '2025-02-03 11:45:00+00'::timestamptz
  ) THEN
    RAISE EXCEPTION 'legacy tasks with invalid reporting timezones did not receive safe zones or changed their task state';
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

  IF EXISTS (
    SELECT expected.id
    FROM (VALUES
      (96000451::bigint, '2024-01-03 09:00:00'::timestamp, '2024-01-05 12:30:00'::timestamp,
       '96000451-0000-4000-8000-000000000001'::uuid, '2024-01-03 09:00:00'::timestamp,
       '2024-01-03 09:00:00'::timestamp, '2024-01-05 12:30:00'::timestamp),
      (96000452::bigint, '2024-01-05 12:30:00'::timestamp, NULL::timestamp,
       '96000452-0000-4000-8000-000000000002'::uuid, '2024-01-05 12:30:00'::timestamp,
       '2024-01-05 12:30:00'::timestamp, '2024-01-05 12:30:00'::timestamp)
    ) AS expected(id, entered_at, exited_at, correlation_id, reliable_since, created_at, updated_at)
    LEFT JOIN crm_stage_visits visit ON visit.id = expected.id
    WHERE visit.id IS NULL
      OR visit.account_id IS DISTINCT FROM 96000400
      OR visit.deal_id IS DISTINCT FROM 96000450
      OR visit.pipeline_id IS DISTINCT FROM 96000403
      OR visit.stage_id IS DISTINCT FROM 96000404
      OR visit.entered_at IS DISTINCT FROM expected.entered_at
      OR visit.exited_at IS DISTINCT FROM expected.exited_at
      OR visit.estimated IS DISTINCT FROM FALSE
      OR visit.reliable_since IS DISTINCT FROM expected.reliable_since
      OR visit.pipeline_name IS DISTINCT FROM 'Legacy pipeline'
      OR visit.stage_name IS DISTINCT FROM 'Qualified'
      OR visit.stage_outcome IS DISTINCT FROM 'open'
      OR visit.correlation_id IS DISTINCT FROM expected.correlation_id
      OR visit.created_at IS DISTINCT FROM expected.created_at
      OR visit.updated_at IS DISTINCT FROM expected.updated_at
      OR visit.owner_id_at_terminal IS NOT NULL
      OR visit.team_id_at_terminal IS NOT NULL
      OR visit.terminal_attribution_version IS NOT NULL
  ) OR (SELECT COUNT(*) FROM crm_stage_visits WHERE deal_id = 96000450) <> 2 THEN
    RAISE EXCEPTION 'existing open/closed stage visit history was changed during upgrade';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = current_schema()
      AND table_name = 'crm_stage_visits'
      AND column_name = 'correlation_id'
      AND column_default = 'gen_random_uuid()'
  ) THEN
    RAISE EXCEPTION 'legacy stage visit correlation IDs did not receive the declared UUID default';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (VALUES
      ('owner_id_at_terminal', 'bigint'),
      ('team_id_at_terminal', 'bigint'),
      ('terminal_attribution_version', 'integer')
    ) AS expected(column_name, data_type)
    LEFT JOIN information_schema.columns column_info
      ON column_info.table_schema = current_schema()
      AND column_info.table_name = 'crm_stage_visits'
      AND column_info.column_name = expected.column_name
    WHERE column_info.column_name IS NULL
      OR column_info.data_type IS DISTINCT FROM expected.data_type
      OR column_info.is_nullable IS DISTINCT FROM 'YES'
      OR column_info.column_default IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'terminal attribution columns do not match the nullable legacy-safe contract';
  END IF;

  IF (SELECT COUNT(*) FROM pg_constraint constraint_info
      WHERE constraint_info.conrelid = 'crm_stage_visits'::regclass
        AND constraint_info.conname IN (
          'crm_stage_visits_valid_interval',
          'crm_stage_visits_terminal_attribution_valid',
          'fk_rails_fe6b2ed84c',
          'fk_rails_9e8c29505f',
          'fk_rails_a5e04db761',
          'fk_rails_225caa8bbd'
        )) <> 6
     OR (SELECT COUNT(*) FROM pg_indexes index_info
         WHERE index_info.schemaname = current_schema()
           AND index_info.tablename = 'crm_stage_visits'
           AND index_info.indexname IN (
             'index_crm_stage_visits_on_account_id',
             'index_crm_stage_visits_on_account_id_and_entered_at',
             'index_crm_stage_visits_on_account_id_and_exited_at',
             'index_crm_stage_visits_on_active_deal',
             'index_crm_stage_visits_on_correlation_id',
             'index_crm_stage_visits_on_deal_id',
             'index_crm_stage_visits_on_pipeline_id',
             'index_crm_stage_visits_on_stage_id'
           )) <> 8 THEN
    RAISE EXCEPTION 'existing stage visit constraints or indexes were not retained and completed';
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
