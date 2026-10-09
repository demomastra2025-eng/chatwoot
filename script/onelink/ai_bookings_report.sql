-- Read-only. Bind $1::integer = hours (1..168), $2::bigint = account id or NULL,
-- $3::text = comma-separated rule codes (NULL for all). The rake task uses this exact query.
-- Thresholds live here; changing them changes both the report and monitor.
WITH limits AS MATERIALIZED (
  SELECT clock.checked_at, clock.checked_at - ($1::integer * interval '1 hour') AS since,
         $2::bigint AS account_id, $3::text AS rules,
         interval '2 minutes' AS unbound_pending,
         interval '5 minutes' AS warning_age,
         interval '15 minutes' AS critical_age,
         interval '10 minutes' AS notification_age
  FROM (SELECT clock_timestamp() AS checked_at) clock
), ai AS MATERIALIZED (
  SELECT a.id, a.account_id, a.contact_id, a.patient_contact_id,
         a.conversation_id, a.resource_id, a.starts_at, a.ends_at,
         a.status, a.source, a.created_at, a.custom_attributes
  FROM scheduling_appointments a CROSS JOIN limits l
  WHERE a.created_at >= l.since AND a.created_at <= l.checked_at
    AND (l.account_id IS NULL OR a.account_id = l.account_id)
    AND (a.source = 'captain' OR EXISTS (
      SELECT 1 FROM medelement_provider_commands c
      WHERE c.appointment_id = a.id AND c.account_id = a.account_id
        AND c.operation = 'create_reception'
        AND c.execution_state #>> '{request_snapshot,actor,type}' = 'Captain::Assistant'
    ))
), commands AS MATERIALIZED (
  SELECT c.id, c.account_id, c.appointment_id, c.status, c.operation,
         c.created_at, c.updated_at, c.executed_at, c.provider_reception_code,
         c.execution_state
  FROM medelement_provider_commands c JOIN ai a
    ON a.id = c.appointment_id AND a.account_id = c.account_id
  WHERE c.operation = 'create_reception'
), linked AS MATERIALIZED (
  SELECT a.*, c.id AS command_id, c.status AS command_status,
         c.created_at AS command_created_at, c.updated_at AS command_updated_at,
         c.executed_at, c.provider_reception_code, c.execution_state
  FROM ai a LEFT JOIN LATERAL (
    SELECT c.* FROM medelement_provider_commands c
    WHERE c.appointment_id = a.id AND c.account_id = a.account_id
      AND c.operation = 'create_reception'
    ORDER BY (c.id::text = a.custom_attributes ->> 'medelement_provider_command_id') DESC,
             c.created_at DESC, c.id DESC LIMIT 1
  ) c ON true
), local_windows AS MATERIALIZED (
  -- Rails datetime columns store UTC timestamps without a time zone.
  SELECT a.id AS appointment_id,
         (a.starts_at AT TIME ZONE 'UTC') AT TIME ZONE r.timezone AS local_starts_at,
         (a.ends_at AT TIME ZONE 'UTC') AT TIME ZONE r.timezone AS local_ends_at
  FROM linked a JOIN scheduling_resources r ON r.id = a.resource_id
), findings AS (
  SELECT a.account_id, a.id AS appointment_id, a.command_id, a.conversation_id,
         'A1_CREATE_PENDING'::text AS rule, 'warning'::text AS severity,
         EXTRACT(EPOCH FROM (l.checked_at - COALESCE(a.command_created_at, a.created_at)))::integer AS age_seconds
  FROM linked a CROSS JOIN limits l
  WHERE a.status IN ('scheduled', 'confirmed') AND a.command_id IS NOT NULL
    AND a.command_status <> 'succeeded'
    AND l.checked_at - a.command_created_at >= l.warning_age
    AND l.checked_at - a.command_created_at < l.critical_age
  UNION ALL
  SELECT a.account_id, a.id, a.command_id, a.conversation_id,
         'A1_CREATE_CRITICAL', 'critical',
         EXTRACT(EPOCH FROM (l.checked_at - a.command_created_at))::integer
  FROM linked a CROSS JOIN limits l
  WHERE a.status IN ('scheduled', 'confirmed') AND a.command_id IS NOT NULL
    AND a.command_status <> 'succeeded'
    AND l.checked_at - a.command_created_at >= l.critical_age
  UNION ALL
  SELECT a.account_id, a.id, NULL::bigint, a.conversation_id,
         'A1_UNBOUND_PENDING', 'warning',
         EXTRACT(EPOCH FROM (l.checked_at - a.created_at))::integer
  FROM linked a CROSS JOIN limits l
  WHERE a.status IN ('scheduled', 'confirmed')
    AND a.custom_attributes ->> 'medelement_provider_sync_status' = 'pending'
    AND NOT EXISTS (
      SELECT 1 FROM medelement_provider_commands c
      WHERE c.appointment_id = a.id AND c.account_id = a.account_id
        AND c.operation = 'create_reception'
        AND c.id::text = a.custom_attributes ->> 'medelement_provider_command_id'
    )
    AND l.checked_at - a.created_at >= l.unbound_pending
  UNION ALL
  SELECT a.account_id, a.id, a.command_id, a.conversation_id,
         CASE WHEN a.command_status LIKE '%provider_status_unknown' THEN 'A2_PROVIDER_UNKNOWN'
              WHEN a.command_status LIKE '%reconciliation_required' THEN 'A2_RECONCILIATION'
              WHEN a.command_status LIKE '%awaiting_patient_%' THEN 'A2_AWAITING_PATIENT'
              ELSE 'A2_COMMAND_' || upper(a.command_status) END,
         CASE WHEN a.command_status LIKE '%provider_status_unknown' THEN 'critical'
              WHEN a.command_status LIKE '%awaiting_patient_%' THEN 'needs_human'
              ELSE 'warning' END,
         EXTRACT(EPOCH FROM (l.checked_at - a.command_updated_at))::integer
  FROM linked a CROSS JOIN limits l
  WHERE a.command_status IN ('failed', 'declined', 'cancelled',
         'provider_status_unknown', 'v2_provider_status_unknown',
         'awaiting_patient_selection', 'awaiting_patient_creation',
         'v2_awaiting_patient_selection', 'v2_awaiting_patient_creation')
     OR (a.command_status IN ('reconciliation_required', 'v2_reconciliation_required')
         AND l.checked_at - a.command_updated_at >= l.warning_age)
  UNION ALL
  SELECT a.account_id, a.id, a.command_id, a.conversation_id,
         'A4_DUPLICATE', 'warning', EXTRACT(EPOCH FROM (l.checked_at - a.created_at))::integer
  FROM linked a CROSS JOIN limits l
  WHERE a.status IN ('scheduled', 'confirmed') AND a.contact_id IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM scheduling_appointments b
      WHERE b.account_id = a.account_id AND b.resource_id = a.resource_id
        AND b.starts_at = a.starts_at AND b.id <> a.id
        AND b.status IN ('scheduled', 'confirmed') AND b.contact_id = a.contact_id
        AND b.patient_contact_id IS NOT DISTINCT FROM a.patient_contact_id
    )
  UNION ALL
  SELECT a.account_id, a.id, a.command_id, a.conversation_id,
         'A4_DOCTOR_OVERLAP', 'warning', EXTRACT(EPOCH FROM (l.checked_at - a.created_at))::integer
  FROM linked a CROSS JOIN limits l
  WHERE a.status IN ('scheduled', 'confirmed') AND EXISTS (
    SELECT 1 FROM scheduling_appointments b
    WHERE b.account_id = a.account_id AND b.resource_id = a.resource_id AND b.id <> a.id
      AND b.starts_at < a.ends_at AND b.ends_at > a.starts_at
      AND b.status IN ('scheduled', 'confirmed')
      AND NOT (b.starts_at = a.starts_at AND b.contact_id IS NOT DISTINCT FROM a.contact_id
               AND b.patient_contact_id IS NOT DISTINCT FROM a.patient_contact_id)
  )
  UNION ALL
  SELECT a.account_id, a.id, a.command_id, a.conversation_id,
         'A4_CABINET_OVERLAP', 'warning', EXTRACT(EPOCH FROM (l.checked_at - a.created_at))::integer
  FROM linked a CROSS JOIN limits l
  WHERE a.status IN ('scheduled', 'confirmed')
    AND a.custom_attributes ->> 'medelement_cabinet_code' IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM scheduling_appointments b
      WHERE b.account_id = a.account_id AND b.id <> a.id
        AND b.resource_id <> a.resource_id AND b.starts_at < a.ends_at AND b.ends_at > a.starts_at
        AND b.status IN ('scheduled', 'confirmed')
        AND b.custom_attributes ->> 'medelement_cabinet_code' =
            a.custom_attributes ->> 'medelement_cabinet_code'
    )
  UNION ALL
  SELECT m.account_id, NULL::bigint, NULL::bigint, m.conversation_id,
         'A5_CLAIM_WITHOUT_SUCCESS', 'needs_review',
         EXTRACT(EPOCH FROM (l.checked_at - m.created_at))::integer
  FROM messages m CROSS JOIN limits l
  WHERE m.created_at >= l.since AND m.created_at <= l.checked_at
    AND (l.account_id IS NULL OR m.account_id = l.account_id)
    AND m.sender_type = 'Captain::Assistant' AND m.message_type = 1 AND m.private = false
    AND lower(m.content) ~
      '(вы записаны|вас записал[аи]?|запись подтверждена|сіз жазылдыңыз|сізді жазып қойдым)'
    AND (
      EXISTS (
        SELECT 1 FROM jsonb_array_elements(
          CASE WHEN jsonb_typeof(m.additional_attributes #> '{captain_trace,tool_steps}') = 'array'
               THEN m.additional_attributes #> '{captain_trace,tool_steps}' ELSE '[]'::jsonb END
        ) step
        WHERE step ->> 'tool_name' = 'create_appointment'
          AND step ->> 'event' IN ('failed', 'error')
      ) OR EXISTS (
        SELECT 1 FROM llm_events e
        WHERE e.account_id = m.account_id AND e.conversation_id = m.conversation_id
          AND e.event_name = 'llm.tool.complete'
          AND e.tool_name = 'create_appointment' AND e.created_at BETWEEN m.created_at - interval '5 minutes' AND m.created_at
          AND e.payload ->> 'result_success' = 'false'
      ) OR (
        EXISTS (
          SELECT 1 FROM jsonb_array_elements(
            CASE WHEN jsonb_typeof(m.additional_attributes #> '{captain_trace,tool_steps}') = 'array'
                 THEN m.additional_attributes #> '{captain_trace,tool_steps}' ELSE '[]'::jsonb END
          ) step WHERE step ->> 'tool_name' = 'create_appointment'
        )
      )
    )
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(
        CASE WHEN jsonb_typeof(m.additional_attributes #> '{captain_trace,tool_steps}') = 'array'
             THEN m.additional_attributes #> '{captain_trace,tool_steps}' ELSE '[]'::jsonb END
      ) step
      WHERE step ->> 'tool_name' = 'create_appointment' AND step ->> 'event' = 'finish'
    )
    AND NOT EXISTS (
      SELECT 1 FROM llm_events e
      WHERE e.account_id = m.account_id AND e.conversation_id = m.conversation_id
        AND e.event_name = 'llm.tool.complete'
        AND e.tool_name = 'create_appointment' AND e.created_at BETWEEN m.created_at - interval '5 minutes' AND m.created_at
        AND e.payload ->> 'result_success' = 'true'
    )
  UNION ALL
  SELECT a.account_id, a.id, a.command_id, a.conversation_id,
         'A6_NOTIFICATION_MISSING', 'needs_review',
         EXTRACT(EPOCH FROM (l.checked_at - a.executed_at))::integer
  FROM linked a CROSS JOIN limits l
  WHERE a.command_status = 'succeeded' AND a.executed_at IS NOT NULL
    AND l.checked_at - a.executed_at >= l.notification_age
    AND a.custom_attributes ? 'appointment_created_notification_hold'
    AND NOT EXISTS (
      SELECT 1 FROM reminders r WHERE r.account_id = a.account_id
        AND r.remindable_type = 'Scheduling::Appointment' AND r.remindable_id = a.id
        AND r.created_at >= a.executed_at
    )
    AND NOT EXISTS (
      SELECT 1 FROM messages m WHERE m.account_id = a.account_id
        AND m.conversation_id = a.conversation_id AND m.message_type = 1
        AND m.private = false AND m.created_at >= a.executed_at
        AND m.additional_attributes ->> 'appointment_id' = a.id::text
    )
  UNION ALL
  SELECT a.account_id, a.id, a.command_id, a.conversation_id,
         'A8_CREATED_AFTER_START', 'warning',
         EXTRACT(EPOCH FROM (l.checked_at - a.created_at))::integer
  FROM linked a CROSS JOIN limits l WHERE a.created_at > a.starts_at
  UNION ALL
  SELECT a.account_id, a.id, a.command_id, a.conversation_id,
         'A8_OUTSIDE_WORK_WINDOW', 'warning',
         EXTRACT(EPOCH FROM (l.checked_at - a.created_at))::integer
  FROM linked a JOIN local_windows lw ON lw.appointment_id = a.id
    JOIN scheduling_resources r ON r.id = a.resource_id CROSS JOIN limits l
  WHERE EXISTS (SELECT 1 FROM scheduling_work_rules w WHERE w.resource_id = r.id AND w.active)
    AND NOT EXISTS (
      SELECT 1 FROM scheduling_workday_overrides o
      WHERE o.resource_id = r.id AND o.date = lw.local_starts_at::date
        AND o.start_minute <= EXTRACT(HOUR FROM lw.local_starts_at) * 60 +
                              EXTRACT(MINUTE FROM lw.local_starts_at)
        AND o.end_minute >= EXTRACT(HOUR FROM lw.local_ends_at) * 60 +
                            EXTRACT(MINUTE FROM lw.local_ends_at)
    )
    AND (EXISTS (
      SELECT 1 FROM scheduling_workday_overrides o
      WHERE o.resource_id = r.id AND o.date = lw.local_starts_at::date
    ) OR NOT EXISTS (
      SELECT 1 FROM scheduling_work_rules w
      WHERE w.resource_id = r.id AND w.active
        AND w.weekday = EXTRACT(DOW FROM lw.local_starts_at)
        AND w.start_minute <= EXTRACT(HOUR FROM lw.local_starts_at) * 60 +
                              EXTRACT(MINUTE FROM lw.local_starts_at)
        AND w.end_minute >= EXTRACT(HOUR FROM lw.local_ends_at) * 60 +
                            EXTRACT(MINUTE FROM lw.local_ends_at)
    ))
), timezone_symptoms AS (
  SELECT f.account_id, f.appointment_id, f.command_id, f.conversation_id,
         'A8_TIMEZONE_SUSPECT'::text AS rule, 'needs_review'::text AS severity,
         f.age_seconds
  FROM findings f JOIN linked a ON a.id = f.appointment_id
    JOIN local_windows lw ON lw.appointment_id = a.id
  WHERE f.rule = 'A8_OUTSIDE_WORK_WINDOW'
    AND EXISTS (
      SELECT 1 FROM (VALUES (-6), (-5), (-3), (3), (5), (6)) shift(hours)
        JOIN scheduling_work_rules w ON w.resource_id = a.resource_id AND w.active
      WHERE w.weekday = EXTRACT(DOW FROM lw.local_starts_at + shift.hours * interval '1 hour')
        AND w.start_minute <= EXTRACT(HOUR FROM lw.local_starts_at + shift.hours * interval '1 hour') * 60 +
                              EXTRACT(MINUTE FROM lw.local_starts_at + shift.hours * interval '1 hour')
        AND w.end_minute >= EXTRACT(HOUR FROM lw.local_ends_at + shift.hours * interval '1 hour') * 60 +
                            EXTRACT(MINUTE FROM lw.local_ends_at + shift.hours * interval '1 hour')
    )
), report_accounts AS (
  SELECT account_id FROM ai
  UNION
  SELECT account_id FROM findings
  WHERE rule = 'A5_CLAIM_WITHOUT_SUCCESS' AND (SELECT rules FROM limits) IS NULL
  UNION
  SELECT account_id FROM limits WHERE account_id IS NOT NULL
), totals AS (
  SELECT ids.account_id,
         (SELECT count(*)::integer FROM ai a WHERE a.account_id = ids.account_id) AS ai_appointments,
         (SELECT COALESCE(jsonb_object_agg(status, n), '{}'::jsonb) FROM (
           SELECT x.status, count(*)::integer AS n FROM ai x
           WHERE x.account_id = ids.account_id GROUP BY x.status
         ) statuses) AS appointments_by_status,
         (SELECT COALESCE(jsonb_object_agg(status, n), '{}'::jsonb) FROM (
           SELECT c.status, count(*)::integer AS n FROM commands c
           WHERE c.account_id = ids.account_id GROUP BY c.status
         ) statuses) AS commands_by_status
  FROM report_accounts ids
)
SELECT 'total' AS record_type, t.account_id, NULL::bigint AS appointment_id,
       NULL::bigint AS command_id, NULL::bigint AS conversation_id,
       NULL::text AS rule, NULL::text AS severity, NULL::integer AS age_seconds,
       t.ai_appointments, t.appointments_by_status, t.commands_by_status
FROM totals t
UNION ALL
SELECT 'anomaly', f.account_id, f.appointment_id, f.command_id,
       f.conversation_id, f.rule, f.severity, f.age_seconds,
       NULL::integer, NULL::jsonb, NULL::jsonb
FROM (SELECT * FROM findings UNION ALL SELECT * FROM timezone_symptoms) f CROSS JOIN limits l
WHERE l.rules IS NULL OR f.rule = ANY(string_to_array(l.rules, ','))
ORDER BY account_id, record_type DESC, appointment_id, rule;
