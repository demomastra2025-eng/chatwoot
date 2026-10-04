-- Apply after loading the target base schema and before pending CRM migrations.
-- This fixture is for the isolated migration database only.
BEGIN;

INSERT INTO accounts (id, name, settings, created_at, updated_at)
VALUES (96000400, 'CRM lifecycle migration fixture', '{"reporting_timezone":"Europe/Berlin"}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);

INSERT INTO crm_task_statuses (id, account_id, name, code, position, category, active, "default", created_at, updated_at)
VALUES (96000402, 96000400, 'Open', 'open', 1, 'open', TRUE, TRUE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);

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

INSERT INTO crm_events (account_id, eventable_type, eventable_id, event_type, meta, created_at)
VALUES (96000400, 'Crm::Deal', 96000409, 'legacy.event', '{"fixture":true}', CURRENT_TIMESTAMP);

COMMIT;
