-- Apply after all pending migrations on the isolated migration database.
-- Validate the pre-existing Captain table contract and preservation of both
-- complete synthetic rows; this fixture never deletes or rewrites data.
DO $$
DECLARE
  expected_attempt jsonb;
  actual_attempt jsonb;
  expected_reminder jsonb;
  actual_reminder jsonb;
BEGIN
  IF (SELECT COUNT(*) FROM captain_follow_up_attempts_legacy_snapshot) <> 1 THEN
    RAISE EXCEPTION 'Captain legacy attempt snapshot is missing or ambiguous';
  END IF;

  SELECT row_data INTO expected_attempt
  FROM captain_follow_up_attempts_legacy_snapshot
  WHERE id = 96000720;
  SELECT to_jsonb(attempt) INTO actual_attempt
  FROM captain_follow_up_attempts AS attempt
  WHERE id = 96000720;
  IF actual_attempt IS DISTINCT FROM expected_attempt THEN
    RAISE EXCEPTION 'pre-existing completed Captain attempt row was not preserved exactly';
  END IF;

  IF (SELECT COUNT(*) FROM reminder_idempotency_legacy_snapshot) <> 1 THEN
    RAISE EXCEPTION 'Reminder idempotency legacy snapshot is missing or ambiguous';
  END IF;

  SELECT row_data INTO expected_reminder
  FROM reminder_idempotency_legacy_snapshot
  WHERE id = 96000721;
  SELECT to_jsonb(reminder) INTO actual_reminder
  FROM reminders AS reminder
  WHERE id = 96000721;
  IF actual_reminder IS DISTINCT FROM expected_reminder THEN
    RAISE EXCEPTION 'pre-existing reminder row, idempotency key, content, or TTL was not preserved exactly';
  END IF;

  IF (SELECT COUNT(*) FROM information_schema.columns
      WHERE table_schema = current_schema()
        AND table_name = 'captain_follow_up_attempts') <> 15 THEN
    RAISE EXCEPTION 'Captain attempt table no longer has the canonical 15-column shape';
  END IF;

  IF EXISTS (
    SELECT expected.column_name
    FROM (VALUES
      ('id', 'bigint', NULL::integer, 'NO', NULL::integer),
      ('account_id', 'bigint', NULL::integer, 'NO', NULL::integer),
      ('assistant_id', 'bigint', NULL::integer, 'NO', NULL::integer),
      ('conversation_id', 'bigint', NULL::integer, 'NO', NULL::integer),
      ('anchor_message_id', 'bigint', NULL::integer, 'NO', NULL::integer),
      ('step_index', 'integer', NULL::integer, 'NO', NULL::integer),
      ('attempt_key', 'character varying', 64, 'NO', NULL::integer),
      ('generated_content', 'text', NULL::integer, 'YES', NULL::integer),
      ('status', 'character varying', NULL::integer, 'NO', NULL::integer),
      ('processing_started_at', 'timestamp without time zone', NULL::integer, 'NO', 6),
      ('generated_at', 'timestamp without time zone', NULL::integer, 'YES', 6),
      ('completed_at', 'timestamp without time zone', NULL::integer, 'YES', 6),
      ('expires_at', 'timestamp without time zone', NULL::integer, 'NO', 6),
      ('created_at', 'timestamp without time zone', NULL::integer, 'NO', 6),
      ('updated_at', 'timestamp without time zone', NULL::integer, 'NO', 6)
    ) AS expected(column_name, data_type, character_maximum_length, is_nullable, datetime_precision)
    LEFT JOIN information_schema.columns actual
      ON actual.table_schema = current_schema()
      AND actual.table_name = 'captain_follow_up_attempts'
      AND actual.column_name = expected.column_name
    WHERE actual.column_name IS NULL
      OR actual.data_type IS DISTINCT FROM expected.data_type
      OR actual.character_maximum_length IS DISTINCT FROM expected.character_maximum_length
      OR actual.is_nullable IS DISTINCT FROM expected.is_nullable
      OR actual.datetime_precision IS DISTINCT FROM expected.datetime_precision
  ) THEN
    RAISE EXCEPTION 'Captain attempt columns do not match the canonical type, length, nullability, or precision contract';
  END IF;

  IF (SELECT column_default FROM information_schema.columns
      WHERE table_schema = current_schema()
        AND table_name = 'captain_follow_up_attempts'
        AND column_name = 'status') IS DISTINCT FROM '''processing''::character varying' THEN
    RAISE EXCEPTION 'Captain attempt status default does not match the canonical contract';
  END IF;

  IF (SELECT COUNT(*) FROM pg_index
      WHERE indrelid = 'captain_follow_up_attempts'::regclass) <> 8
     OR EXISTS (
       SELECT 1 FROM pg_index
       WHERE indrelid = 'captain_follow_up_attempts'::regclass
         AND (NOT indisvalid OR NOT indisready)
     )
     OR ARRAY(
       SELECT index_class.relname
       FROM pg_index index_info
       JOIN pg_class index_class ON index_class.oid = index_info.indexrelid
       WHERE index_info.indrelid = 'captain_follow_up_attempts'::regclass
       ORDER BY index_class.relname
     ) IS DISTINCT FROM ARRAY[
       'captain_follow_up_attempts_pkey',
       'index_captain_follow_up_attempts_on_account_id',
       'index_captain_follow_up_attempts_on_anchor_and_created_at',
       'index_captain_follow_up_attempts_on_anchor_message_id',
       'index_captain_follow_up_attempts_on_assistant_id',
       'index_captain_follow_up_attempts_on_attempt_key',
       'index_captain_follow_up_attempts_on_conversation_id',
       'index_captain_follow_up_attempts_on_status_and_expires_at'
     ]::name[] THEN
    RAISE EXCEPTION 'Captain attempt table does not retain exactly the eight valid canonical indexes';
  END IF;

  IF EXISTS (
    SELECT expected.index_name
    FROM (VALUES
      ('captain_follow_up_attempts_pkey', 'id', TRUE),
      ('index_captain_follow_up_attempts_on_account_id', 'account_id', FALSE),
      ('index_captain_follow_up_attempts_on_assistant_id', 'assistant_id', FALSE),
      ('index_captain_follow_up_attempts_on_conversation_id', 'conversation_id', FALSE),
      ('index_captain_follow_up_attempts_on_anchor_message_id', 'anchor_message_id', FALSE),
      ('index_captain_follow_up_attempts_on_attempt_key', 'attempt_key', TRUE),
      ('index_captain_follow_up_attempts_on_anchor_and_created_at', 'anchor_message_id, created_at', FALSE),
      ('index_captain_follow_up_attempts_on_status_and_expires_at', 'status, expires_at', FALSE)
    ) AS expected(index_name, columns, is_unique)
    LEFT JOIN pg_class index_class ON index_class.relname = expected.index_name
    LEFT JOIN pg_index index_info
      ON index_info.indexrelid = index_class.oid
      AND index_info.indrelid = 'captain_follow_up_attempts'::regclass
    WHERE index_info.indexrelid IS NULL
      OR index_info.indisunique IS DISTINCT FROM expected.is_unique
      OR pg_get_indexdef(index_info.indexrelid) NOT LIKE ('%(' || expected.columns || ')%')
  ) THEN
    RAISE EXCEPTION 'Captain attempt index names, uniqueness, or indexed columns do not match the canonical contract';
  END IF;

  IF (SELECT COUNT(*) FROM pg_constraint
      WHERE conrelid = 'captain_follow_up_attempts'::regclass
        AND contype = 'f') <> 4
     OR EXISTS (
       SELECT expected.constraint_name
       FROM (VALUES
         ('fk_rails_8b6ef2dbf7', 'account_id', 'accounts'),
         ('fk_rails_39a5d09c2f', 'assistant_id', 'captain_assistants'),
         ('fk_rails_c40cf891d9', 'conversation_id', 'conversations'),
         ('fk_rails_8195626a76', 'anchor_message_id', 'messages')
       ) AS expected(constraint_name, column_name, parent_table)
       LEFT JOIN pg_constraint constraint_info
         ON constraint_info.conrelid = 'captain_follow_up_attempts'::regclass
         AND constraint_info.conname = expected.constraint_name
         AND constraint_info.contype = 'f'
       LEFT JOIN pg_class parent_table ON parent_table.oid = constraint_info.confrelid
       LEFT JOIN pg_attribute child_column
         ON child_column.attrelid = 'captain_follow_up_attempts'::regclass
         AND child_column.attname = expected.column_name
       LEFT JOIN pg_attribute parent_id
         ON parent_id.attrelid = constraint_info.confrelid
         AND parent_id.attname = 'id'
       WHERE constraint_info.oid IS NULL
         OR parent_table.relname IS DISTINCT FROM expected.parent_table
         OR constraint_info.conkey IS DISTINCT FROM ARRAY[child_column.attnum]::smallint[]
         OR constraint_info.confkey IS DISTINCT FROM ARRAY[parent_id.attnum]::smallint[]
         OR constraint_info.confdeltype IS DISTINCT FROM 'c'
         OR NOT constraint_info.convalidated
     ) THEN
    RAISE EXCEPTION 'Captain attempt table does not retain its four validated cascading foreign keys';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = current_schema()
      AND table_name = 'reminders'
      AND column_name = 'idempotency_key'
      AND data_type = 'character varying'
      AND character_maximum_length IS NULL
      AND is_nullable = 'YES'
      AND column_default IS NULL
  ) THEN
    RAISE EXCEPTION 'Reminder idempotency key does not match its nullable unlimited string contract';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_index index_info
    JOIN pg_class index_class ON index_class.oid = index_info.indexrelid
    WHERE index_info.indrelid = 'reminders'::regclass
      AND index_class.relname = 'idx_reminders_on_account_idempotency_key'
      AND index_info.indisunique
      AND index_info.indisvalid
      AND index_info.indisready
      AND index_info.indnkeyatts = 2
      AND regexp_replace(pg_get_expr(index_info.indpred, index_info.indrelid), '[[:space:]()]', '', 'g')
          = 'idempotency_keyISNOTNULL'
      AND pg_get_indexdef(index_info.indexrelid) LIKE '%(account_id, idempotency_key)%'
  ) THEN
    RAISE EXCEPTION 'Reminder account-scoped unique partial idempotency index is missing or invalid';
  END IF;
END;
$$;
