# Compact appointment and deal context

New field selections offer **Appointments → Summary** (`appointment.summary`)
and **Deals → Summary** (`deal.summary`). Both are JSON objects with version 1.
Captain prompts, field references in outbound text, Liquid runtime drops and
synthetic playground contexts use the same summary contract.

The envelope contains `kind`, `counts`, `groups`, `shown`, `total`, `display`,
`scope`, `selection`, `sort`, `details_tool` and `search_tool`. Every group has
`key`, `items`, `shown`, `total`, `display`, `limit` and `sort`. `display` always
states "Показано X из Y". Row limits are fixed per group and unused slots are
never redistributed. The total describes all scoped records, not only the rows
loaded for the prompt. SQL counts and limited queries avoid loading an entire
patient or contact history.

| Summary | Groups and limits | Ordering |
| --- | --- | --- |
| Deals | 8 active, 4 closed/archived | Active: updated_at DESC, id DESC. History: latest closed_at/archived_at DESC, id DESC. |
| Appointments | 6 upcoming/ongoing, 3 past, 3 cancelled | Ongoing first, then starts_at ASC/id ASC; past ends_at DESC/id DESC; cancelled planned starts_at DESC/id DESC. |

A contact with 5 active and 295 historical deals sees **9 of 300**, with **5 of 5**
and **4 of 295** in the two groups. A closed stage with no actual close/archive
timestamp uses `created_at` only for stable sorting; `history_at_source` is
`created_at_fallback_event_time_unknown`. It does not claim the record was closed
then. Cancellation ordering never uses `updated_at` as a cancellation date.

Summaries carry exact row IDs and titles/names so the model can explicitly call
`get_deal` or `get_appointment`. They do not select a current/main deal and do not
expose a separate global deal ID or title. Generic deal scalar context is empty.
Explicit CRM event data and an explicitly passed `deal:` preserve the original
scalar types for existing templates.

## Scope and access

All queries are account scoped. Deal rows require an account-scoped `DealContact`
link to the current contact. Appointment rows require both the communication
contact and `COALESCE(patient_contact_id, contact_id)` to equal the current contact,
matching patient tools. A mother's telephone number does not include a child's
records. Actor permission checks remain in catalogs and rendering. Explicit
other-patient lookup/task-token flows do not widen default summaries.

## Paging and full records

`search_deals` retains its existing filters and response `deals`/`total_count`.
It additionally accepts optional `status` (`active`, `closed`, `archived`, `any`)
and nonnegative integer `offset`. Omitting `status` preserves the old `archived`
filter. Page size remains capped at 50. Responses include `shown`, `limit`,
`offset`, `has_more`, `next_offset` and deterministic `sort`. Patients remain
restricted to their own deals even with a title query or an offset. Employees'
title queries retain their permitted account scope.

`list_my_appointments` already supports status, calendar-date and doctor filters,
offset paging and a 20-row cap. Full-card tools keep their existing authorization.
Stage transitions now take an explicit `deal_id`; public tools also accept an
explicit legacy CRM-event state ID. Updates accept a verified explicit deal ID.
Adding deal comments requires `deal_id` as well. The legacy
`list_deal_stages(current_deal: true)` selector returns a migration error unless
an explicit deal/pipeline selector is supplied.

CRM reminder text passes its exact `remindable` deal to the outbound renderer.
AI-generated CRM touches pass that same record to the runner, which checks the
exact account/contact link before exposing scalar fields. Neither caller
substitutes a newer deal from the delivery conversation.

## Saved field migration

No data migration rewrites templates or customer/profile records. Old appointment
fields/blocks and deal scalar/custom fields remain in the catalog with
`deprecated: true`, `selectable: false`, and `replacement_field_id`. Existing
selected/used entries remain visible with a migration warning; new selectors hide
them. Captain prompt state includes `context_warnings` for selected legacy fields.

Switch saved references to `*.summary` explicitly only after reviewing the
template or custom tool's expected JSON type. Existing scalar references retain
their scalar representation and require an explicit deal/CRM event; they never
pick the latest deal. Scopes saved without a field whitelist preserve the old
scalar whitelist until explicitly updated. New scheduling profiles recommend
only `appointment.summary`. No destructive SQL migration is required.

Saved-production-template/profile usage must be audited through a separately
authorized read-only environment before rollout; this local change does not
inspect or edit customer data.
