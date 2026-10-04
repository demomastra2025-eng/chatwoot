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
VALUES (96000409, 96000400, 96000403, 96000404, 'Legacy deal', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);

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
