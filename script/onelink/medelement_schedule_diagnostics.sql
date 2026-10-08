-- Read-only schedule eligibility probe. Outputs only identifiers, counts, statuses and error codes.
-- Run with psql -X -v ON_ERROR_STOP=1. No Rails boot or provider requests are required.
BEGIN READ ONLY;
SET LOCAL statement_timeout = '10s';

WITH hooks AS (
  SELECT id, account_id, status,
         CASE WHEN NOT (settings ? 'sync_specialists') THEN true
              ELSE lower(coalesce(settings ->> 'sync_specialists', '')) NOT IN ('', '0', 'f', 'false', 'off')
         END AS sync_specialists_enabled
  FROM integrations_hooks
  WHERE app_id = 'medelement' AND account_id IN (43, 64, 74, 76, 77, 78, 89, 90)
), resources AS (
  SELECT r.account_id, r.active,
         NOT (r.custom_attributes @> '{"deleted_from_scheduling":true}'::jsonb) AS available,
         nullif(r.custom_attributes ->> 'medelement_specialist_code', '') IS NOT NULL AS has_code,
         r.custom_attributes ->> 'medelement_last_seen_at' AS last_seen
  FROM scheduling_resources r
  WHERE r.account_id IN (SELECT account_id FROM hooks)
), eligibility AS (
  SELECT account_id, count(*) AS resources_count,
         count(*) FILTER (WHERE active AND available) AS available_count,
         count(*) FILTER (WHERE active AND available AND has_code) AS coded_available_count,
         count(*) FILTER (WHERE active AND available AND has_code AND last_seen IS NULL) AS no_last_seen_count,
         -- Sync writes Time.current.iso8601 in UTC. Text comparison avoids casting damaged JSON timestamps.
         count(*) FILTER (
           WHERE active AND available AND has_code
             AND last_seen ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|\+00:00)$'
             AND left(last_seen, 19) >= to_char((now() AT TIME ZONE 'UTC') - interval '1 hour', 'YYYY-MM-DD"T"HH24:MI:SS')
         ) AS recent_utc_coded_count,
         count(*) FILTER (
           WHERE active AND available AND has_code AND last_seen IS NOT NULL
             AND last_seen !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|\+00:00)$'
         ) AS unclassified_last_seen_count
  FROM resources GROUP BY account_id
), shadow AS (
  SELECT hook_id, count(*) AS schedule_days_count, count(DISTINCT resource_id) AS scheduled_resources_count,
         count(*) FILTER (WHERE status = 'confirmed') AS confirmed_count,
         count(*) FILTER (WHERE status = 'unverified') AS unverified_count
  FROM medelement_schedule_days WHERE hook_id IN (SELECT id FROM hooks) GROUP BY hook_id
)
SELECT h.account_id, h.id AS hook_id, h.status, h.sync_specialists_enabled,
       coalesce(e.resources_count, 0) AS resources_count, coalesce(e.available_count, 0) AS available_count,
       coalesce(e.coded_available_count, 0) AS coded_available_count,
       coalesce(e.recent_utc_coded_count, 0) AS recent_utc_coded_count,
       coalesce(e.no_last_seen_count, 0) AS no_last_seen_count,
       coalesce(e.unclassified_last_seen_count, 0) AS unclassified_last_seen_count,
       coalesce(s.schedule_days_count, 0) AS schedule_days_count,
       coalesce(s.scheduled_resources_count, 0) AS scheduled_resources_count,
       coalesce(s.confirmed_count, 0) AS confirmed_count, coalesce(s.unverified_count, 0) AS unverified_count
FROM hooks h LEFT JOIN eligibility e USING (account_id) LEFT JOIN shadow s ON s.hook_id = h.id
ORDER BY h.account_id;

WITH ranked AS (
  SELECT r.*, row_number() OVER (PARTITION BY r.hook_id ORDER BY r.created_at DESC, r.id DESC) AS position
  FROM medelement_sync_runs r JOIN integrations_hooks h ON h.id = r.hook_id
  WHERE h.app_id = 'medelement' AND h.account_id IN (89, 90)
)
SELECT account_id, hook_id, id AS run_id, status, current_phase, error_code,
       floor(extract(epoch FROM now() - updated_at))::bigint AS silence_seconds,
       phase_results #>> '{specialists,status}' AS specialists_status,
       phase_results #>> '{schedules,status}' AS schedules_status,
       phase_results #>> '{schedules,reason}' AS schedules_reason,
       phase_results #>> '{schedules,code}' AS schedules_error_code
FROM ranked WHERE position <= 5 ORDER BY account_id, position;

ROLLBACK;
