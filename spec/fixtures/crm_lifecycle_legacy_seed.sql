-- Apply after loading the target base schema and before pending CRM migrations.
-- This fixture is for the isolated migration database only.
BEGIN;

INSERT INTO accounts (id, name, settings, created_at, updated_at)
VALUES
  (96000400, 'CRM lifecycle migration fixture', '{"reporting_timezone":"Europe/Berlin"}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000420, 'CRM lifecycle missing timezone fixture', '{}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000421, 'CRM lifecycle null timezone fixture', '{"reporting_timezone":null}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000422, 'CRM lifecycle blank timezone fixture', '{"reporting_timezone":""}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000423, 'CRM lifecycle whitespace timezone fixture', '{"reporting_timezone":"   "}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000424, 'CRM lifecycle invalid timezone fixture', '{"reporting_timezone":"Not/A_Real_Zone"}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000425, 'CRM lifecycle display timezone fixture', '{"reporting_timezone":"Eastern Time (US & Canada)"}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);

INSERT INTO crm_task_statuses (id, account_id, name, code, position, category, active, "default", created_at, updated_at)
VALUES
  (96000402, 96000400, 'Open', 'open', 1, 'open', TRUE, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000430, 96000420, 'Open', 'open', 1, 'open', TRUE, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000431, 96000421, 'Open', 'open', 1, 'open', TRUE, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000432, 96000422, 'Open', 'open', 1, 'open', TRUE, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000433, 96000423, 'Open', 'open', 1, 'open', TRUE, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000434, 96000424, 'Open', 'open', 1, 'open', TRUE, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000435, 96000425, 'Open', 'open', 1, 'open', TRUE, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);

INSERT INTO crm_pipelines (id, account_id, name, code, position, active, "default", created_at, updated_at)
VALUES (96000403, 96000400, 'Legacy pipeline', 'legacy-migration-fixture', 1, TRUE, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);

INSERT INTO crm_stages (id, account_id, pipeline_id, name, code, position, outcome, active, created_at, updated_at)
VALUES
  (96000404, 96000400, 96000403, 'Qualified', 'qualified', 1, 'open', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000405, 96000400, 96000403, 'Won', 'won', 2, 'won', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000406, 96000400, 96000403, 'Won duplicate', 'won-duplicate', 3, 'won', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000407, 96000400, 96000403, 'Lost', 'lost', 4, 'lost', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000408, 96000400, 96000403, 'Lost duplicate', 'lost-duplicate', 5, 'lost', TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);

INSERT INTO crm_deals (id, account_id, pipeline_id, stage_id, title, created_at, updated_at)
VALUES
  (96000409, 96000400, 96000403, 96000404, 'Legacy deal', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000450, 96000400, 96000403, 96000404, 'Legacy deal with stage visits', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);

-- Match the pre-migration DEV catalog: stage visits existed, with the base
-- snapshots and constraints, but without terminal attribution columns or a
-- correlation_id default. The migration must upgrade this table in place.
CREATE TABLE crm_stage_visits (
  id bigserial CONSTRAINT crm_stage_visits_pkey PRIMARY KEY,
  account_id bigint NOT NULL,
  deal_id bigint NOT NULL,
  pipeline_id bigint NOT NULL,
  stage_id bigint NOT NULL,
  entered_at timestamp without time zone NOT NULL,
  exited_at timestamp without time zone,
  estimated boolean DEFAULT FALSE NOT NULL,
  reliable_since timestamp without time zone NOT NULL,
  pipeline_name character varying NOT NULL,
  stage_name character varying NOT NULL,
  stage_outcome character varying NOT NULL,
  correlation_id uuid NOT NULL,
  created_at timestamp without time zone NOT NULL,
  updated_at timestamp without time zone NOT NULL,
  CONSTRAINT crm_stage_visits_valid_interval CHECK (exited_at IS NULL OR exited_at >= entered_at),
  CONSTRAINT fk_rails_fe6b2ed84c FOREIGN KEY (account_id) REFERENCES accounts(id),
  CONSTRAINT fk_rails_9e8c29505f FOREIGN KEY (deal_id) REFERENCES crm_deals(id),
  CONSTRAINT fk_rails_a5e04db761 FOREIGN KEY (pipeline_id) REFERENCES crm_pipelines(id),
  CONSTRAINT fk_rails_225caa8bbd FOREIGN KEY (stage_id) REFERENCES crm_stages(id)
);

CREATE INDEX index_crm_stage_visits_on_account_id ON crm_stage_visits (account_id);
CREATE INDEX index_crm_stage_visits_on_account_id_and_entered_at ON crm_stage_visits (account_id, entered_at);
CREATE UNIQUE INDEX index_crm_stage_visits_on_active_deal ON crm_stage_visits (deal_id) WHERE exited_at IS NULL;
CREATE INDEX index_crm_stage_visits_on_correlation_id ON crm_stage_visits (correlation_id);
CREATE INDEX index_crm_stage_visits_on_deal_id ON crm_stage_visits (deal_id);
CREATE INDEX index_crm_stage_visits_on_pipeline_id ON crm_stage_visits (pipeline_id);
CREATE INDEX index_crm_stage_visits_on_stage_id ON crm_stage_visits (stage_id);

INSERT INTO crm_stage_visits (
  id, account_id, deal_id, pipeline_id, stage_id, entered_at, exited_at, estimated,
  reliable_since, pipeline_name, stage_name, stage_outcome, correlation_id, created_at, updated_at
)
VALUES
  (96000451, 96000400, 96000450, 96000403, 96000404, '2024-01-03 09:00:00', '2024-01-05 12:30:00', FALSE,
   '2024-01-03 09:00:00', 'Legacy pipeline', 'Qualified', 'open', '96000451-0000-4000-8000-000000000001',
   '2024-01-03 09:00:00', '2024-01-05 12:30:00'),
  (96000452, 96000400, 96000450, 96000403, 96000404, '2024-01-05 12:30:00', NULL, FALSE,
   '2024-01-05 12:30:00', 'Legacy pipeline', 'Qualified', 'open', '96000452-0000-4000-8000-000000000002',
   '2024-01-05 12:30:00', '2024-01-05 12:30:00');

SELECT setval(pg_get_serial_sequence('crm_stage_visits', 'id'), (SELECT MAX(id) FROM crm_stage_visits));

INSERT INTO crm_tasks (
  id, account_id, status_id, title, activity_type, outcome, position,
  start_at, due_at, created_at, updated_at
)
VALUES (
  96000410, 96000400, 96000402, 'Legacy timed call', 'call', 'cancelled', 0,
  '2025-02-03 10:15:00+00', '2025-02-03 11:45:00+00', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
);

INSERT INTO crm_tasks (
  id, account_id, status_id, title, activity_type, outcome, position,
  start_at, due_at, created_at, updated_at
)
VALUES
  (96000440, 96000420, 96000430, 'Missing timezone task', 'call', 'completed', 0,
   '2025-02-03 10:15:00+00', '2025-02-03 11:45:00+00', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000441, 96000421, 96000431, 'Null timezone task', 'call', 'completed', 0,
   '2025-02-03 10:15:00+00', '2025-02-03 11:45:00+00', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000442, 96000422, 96000432, 'Blank timezone task', 'call', 'completed', 0,
   '2025-02-03 10:15:00+00', '2025-02-03 11:45:00+00', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000443, 96000423, 96000433, 'Whitespace timezone task', 'call', 'completed', 0,
   '2025-02-03 10:15:00+00', '2025-02-03 11:45:00+00', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000444, 96000424, 96000434, 'Invalid timezone task', 'call', 'completed', 0,
   '2025-02-03 10:15:00+00', '2025-02-03 11:45:00+00', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (96000445, 96000425, 96000435, 'Display timezone task', 'call', 'completed', 0,
   '2025-02-03 10:15:00+00', '2025-02-03 11:45:00+00', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);

INSERT INTO crm_events (account_id, eventable_type, eventable_id, event_type, meta, created_at)
VALUES (96000400, 'Crm::Deal', 96000409, 'legacy.event', '{"fixture":true}', CURRENT_TIMESTAMP);

COMMIT;
