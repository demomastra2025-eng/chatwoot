-- Apply after crm_lifecycle_legacy_seed.sql on the isolated migration database,
-- before pending migrations. All additional records below are synthetic.
BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM accounts WHERE id = 96000400) THEN
    RAISE EXCEPTION 'CRM lifecycle synthetic account 96000400 must be seeded first';
  END IF;

  IF to_regclass('captain_follow_up_attempts') IS NOT NULL THEN
    RAISE EXCEPTION 'captain_follow_up_attempts must be absent from the legacy base schema';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = current_schema()
      AND table_name = 'reminders'
      AND column_name = 'idempotency_key'
  ) OR to_regclass('idx_reminders_on_account_idempotency_key') IS NOT NULL THEN
    RAISE EXCEPTION 'reminder idempotency schema must be absent from the legacy base schema';
  END IF;
END;
$$;

-- Reuse the CRM fixture account and provide valid synthetic parent records for
-- the four existing Captain-attempt foreign keys.
INSERT INTO inboxes (id, channel_id, account_id, name, created_at, updated_at, channel_type)
VALUES (96000702, 96000708, 96000400, 'Captain migration fixture inbox', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP,
        'Channel::WebWidget');

INSERT INTO conversations (id, account_id, inbox_id, status, created_at, updated_at, display_id)
VALUES (96000705, 96000400, 96000702, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 96000705);

INSERT INTO messages (id, account_id, inbox_id, conversation_id, message_type, content, created_at, updated_at)
VALUES (96000706, 96000400, 96000702, 96000705, 0,
        'Synthetic anchor message for Captain migration history', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);

INSERT INTO captain_assistants (id, name, account_id, description, created_at, updated_at)
VALUES (96000707, 'Captain migration fixture assistant', 96000400,
        'Synthetic parent for retained follow-up history', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);

-- Match the already-existing DEV table: 15 columns, a bigserial primary key,
-- seven named secondary indexes, and four validated cascading foreign keys.
-- Match the native DEV catalog: all six retained timestamps have precision 6.
CREATE TABLE captain_follow_up_attempts (
  id bigserial CONSTRAINT captain_follow_up_attempts_pkey PRIMARY KEY,
  account_id bigint NOT NULL,
  assistant_id bigint NOT NULL,
  conversation_id bigint NOT NULL,
  anchor_message_id bigint NOT NULL,
  step_index integer NOT NULL,
  attempt_key character varying(64) NOT NULL,
  generated_content text,
  status character varying DEFAULT 'processing'::character varying NOT NULL,
  processing_started_at timestamp(6) without time zone NOT NULL,
  generated_at timestamp(6) without time zone,
  completed_at timestamp(6) without time zone,
  expires_at timestamp(6) without time zone NOT NULL,
  created_at timestamp(6) without time zone NOT NULL,
  updated_at timestamp(6) without time zone NOT NULL,
  CONSTRAINT fk_rails_8b6ef2dbf7 FOREIGN KEY (account_id)
    REFERENCES accounts(id) ON DELETE CASCADE,
  CONSTRAINT fk_rails_39a5d09c2f FOREIGN KEY (assistant_id)
    REFERENCES captain_assistants(id) ON DELETE CASCADE,
  CONSTRAINT fk_rails_c40cf891d9 FOREIGN KEY (conversation_id)
    REFERENCES conversations(id) ON DELETE CASCADE,
  CONSTRAINT fk_rails_8195626a76 FOREIGN KEY (anchor_message_id)
    REFERENCES messages(id) ON DELETE CASCADE
);

CREATE INDEX index_captain_follow_up_attempts_on_account_id
  ON captain_follow_up_attempts (account_id);
CREATE INDEX index_captain_follow_up_attempts_on_assistant_id
  ON captain_follow_up_attempts (assistant_id);
CREATE INDEX index_captain_follow_up_attempts_on_conversation_id
  ON captain_follow_up_attempts (conversation_id);
CREATE INDEX index_captain_follow_up_attempts_on_anchor_message_id
  ON captain_follow_up_attempts (anchor_message_id);
CREATE UNIQUE INDEX index_captain_follow_up_attempts_on_attempt_key
  ON captain_follow_up_attempts (attempt_key);
CREATE INDEX index_captain_follow_up_attempts_on_anchor_and_created_at
  ON captain_follow_up_attempts (anchor_message_id, created_at);
CREATE INDEX index_captain_follow_up_attempts_on_status_and_expires_at
  ON captain_follow_up_attempts (status, expires_at);

-- The legacy reminder table already has this nullable, unlimited-length key
-- and its account-scoped partial unique index on DEV.
ALTER TABLE reminders ADD COLUMN idempotency_key character varying;
CREATE UNIQUE INDEX idx_reminders_on_account_idempotency_key
  ON reminders (account_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;

INSERT INTO captain_follow_up_attempts (
  id, account_id, assistant_id, conversation_id, anchor_message_id, step_index,
  attempt_key, generated_content, status, processing_started_at, generated_at,
  completed_at, expires_at, created_at, updated_at
)
VALUES (
  96000720, 96000400, 96000707, 96000705, 96000706, 2,
  'legacy-captain-follow-up-attempt-96000720',
  'Synthetic completed follow-up retained across migration', 'completed',
  '2026-09-30 08:00:00', '2026-09-30 08:00:04', '2026-09-30 08:00:05',
  '2026-10-07 08:00:00', '2026-09-30 08:00:00', '2026-09-30 08:00:05'
);

INSERT INTO reminders (
  id, account_id, conversation_id, target_conversation_id, status, action_type,
  content_kind, text_mode, timing_mode, auto_cancel_on_incoming, scheduled_at,
  completed_at, timezone, body, instructions, metadata, idempotency_key,
  created_at, updated_at
)
VALUES (
  96000721, 96000400, 96000705, 96000705, 3, 2,
  0, 0, 0, TRUE, '2026-10-05 10:30:00',
  '2026-10-05 10:31:00', 'Europe/Berlin',
  'Synthetic retained reminder body', 'Synthetic retained reminder instructions',
  '{"auto_cancel_on_incoming_explicit":true,"captain_follow_up":{"assistant_id":96000707,"anchor_message_id":96000706,"step_index":2,"control_fence":{"control_generation":0,"status_transition_id":0,"last_message_id":96000706}}}',
  'captain_follow_up:96000707:96000706:2',
  '2026-09-30 08:10:00', '2026-10-05 10:31:00'
);

-- Store the complete rows, including the existing reminder key, for strict
-- post-migration equality checks without reading or copying any live records.
CREATE TABLE captain_follow_up_attempts_legacy_snapshot (
  id bigint PRIMARY KEY,
  row_data jsonb NOT NULL
);
INSERT INTO captain_follow_up_attempts_legacy_snapshot (id, row_data)
SELECT id, to_jsonb(attempt)
FROM captain_follow_up_attempts AS attempt
WHERE id = 96000720;

CREATE TABLE reminder_idempotency_legacy_snapshot (
  id bigint PRIMARY KEY,
  row_data jsonb NOT NULL
);
INSERT INTO reminder_idempotency_legacy_snapshot (id, row_data)
SELECT id, to_jsonb(reminder)
FROM reminders AS reminder
WHERE id = 96000721;

COMMIT;
