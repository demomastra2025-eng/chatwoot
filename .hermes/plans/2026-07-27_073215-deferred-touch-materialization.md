# Deferred Touch Materialization Implementation Plan

> **For Hermes:** Implement this plan task-by-task with TDD, scoped verification, one exact-final independent review, and no PROD mutation without explicit approval.

**Goal:** For appointments and deals, store a touch-plan enrollment up front but create the actual `Reminder` only when a minute-level scheduler determines that a plan step is due, while preserving exactly-once delivery and leaving all existing production reminders untouched.

**Architecture:** Add an account-scoped, feature-gated deferred execution path alongside the current eager `Reminders::ApplyGroupService` path. A lightweight polymorphic enrollment stores a snapshot of the assigned plan and its next due time; a Sidekiq job claims due occurrences with a database unique key, creates a normal `Reminder` immediately before delivery, and then reuses the existing reminder locking, working-hours, message-materialization, retry, and completion pipeline. Existing `Reminder` rows and the current eager path remain unchanged and enabled by default.

**Tech Stack:** Rails 7.1, PostgreSQL, ActiveJob/Sidekiq + sidekiq-cron, existing `Reminder`/`ReminderGroup` services, Vue 3/Vite, RSpec/Vitest.

---

## Non-negotiable behavior and rollout guarantees

1. `deferred_touch_materialization` is disabled by default for every account.
2. No migration, backfill, cancellation, rescheduling, or mutation of existing `reminders` is allowed.
3. Existing draft/pending/processing reminders continue through `Reminders::ProcessPendingRemindersJob` and `Reminders::ExecuteService` unchanged.
4. The new scheduler may only process enrollments created after the account feature is enabled; it must never infer historical enrollments from old appointments, deals, tasks, or reminders.
5. A database unique occurrence key is created before external delivery, so retries and parallel workers cannot send twice.
6. The scheduler never sends to a provider directly. It materializes a normal `Reminder`; the existing delivery pipeline owns message creation and channel delivery.
7. Initial deferred scope is deliberately narrow: one-time relative plan steps for `Scheduling::Appointment` and `Crm::Deal`. Unsupported absolute/recurring/task/conversation plans remain eager until separately implemented and tested.
8. Disabling the feature pauses new deferred enrollments and scheduler materialization but does not delete history. Already materialized reminders continue through the proven existing pipeline.

## Product semantics

- Before trigger: UI shows an active plan enrollment and `next_due_at`, not a future `Reminder`.
- At trigger: one occurrence claim and one `Reminder` are created transactionally.
- Before message materialization: current entity status, anchor, target route, working hours, and effective due time are revalidated.
- After provider delivery: the same `Reminder` becomes `completed`; no post-send-only audit insert is used.
- Entity moved later: enrollment `next_due_at` is recalculated; no stale reminder exists yet.
- Entity moved earlier into the past: allow a small configurable grace window (initially 5 minutes), otherwise mark the occurrence skipped with `missed_due_to_reschedule` and do not send late.
- Entity cancelled/completed/deleted: pause/cancel the enrollment and never materialize a reminder.

---

### Task 1: Lock the contract with characterization tests

**Objective:** Prove the current eager path and existing reminder delivery remain unchanged before adding the deferred path.

**Files:**
- Modify tests only: `spec/services/reminders/apply_group_service_spec.rb`
- Modify tests only: `spec/services/reminders/default_plan_service_spec.rb` (create if absent)
- Modify tests only: `spec/jobs/trigger_scheduled_items_job_spec.rb`
- Modify tests only: `spec/services/reminders/execution_schedule_guard_spec.rb`
- Modify tests only: `spec/services/reminders/execute_service_spec.rb`

**Steps:**
1. Add examples proving an account without the new feature still receives eager `Reminder` rows from default and manual plan application.
2. Add examples proving old pending reminders are still enqueued by `TriggerScheduledItemsJob` regardless of deferred feature state.
3. Add examples proving the existing execution claim and materialized-message idempotency remain authoritative.
4. Repair the three already observed stale specs before using the suite as a gate:
   - `spec/services/reminders/execute_service_spec.rb:680`
   - `spec/services/reminders/execute_service_spec.rb:701`
   - `spec/services/automation_rules/touch_action_service_spec.rb:269`
   Keep runtime route validation strict; make fixtures provide consistent `target_contact_inbox`/conversation routing rather than weakening production validations.
5. Run:
   `bundle exec rspec spec/models/reminder_spec.rb spec/services/reminders/apply_group_service_spec.rb spec/services/reminders/default_plan_service_spec.rb spec/services/reminders/execution_schedule_guard_spec.rb spec/services/reminders/execute_service_spec.rb spec/services/automation_rules/touch_action_service_spec.rb spec/jobs/trigger_scheduled_items_job_spec.rb`
6. Expected: all examples pass before feature implementation continues.

**Commit checkpoint if authorized:** `test(reminders): lock eager touch delivery contracts`

---

### Task 2: Add an additive account-scoped feature gate

**Objective:** Make deferred execution opt-in and impossible to activate accidentally during deploy.

**Files:**
- Modify: `config/features.yml`
- Test: relevant feature/config spec under `spec/configs/`
- Optional account-facing settings only after DEV validation: `app/javascript/dashboard/routes/dashboard/settings/account/Scheduling.vue` and CRM settings pages

**Steps:**
1. Add feature `deferred_touch_materialization` with `enabled: false` and no automatic account enablement.
2. Do not add a global default or migration that turns it on.
3. Add a small policy/service such as `Reminders::DeferredMaterializationPolicy` that returns true only when:
   - account feature is enabled;
   - entity kind is appointment or deal;
   - every plan step is one-time and relative;
   - the relative anchor belongs to the target entity;
   - no unsupported post-delivery/recurrence semantics are present.
4. For unsupported plans, keep the eager path rather than partially deferring steps.
5. Add account-boundary and unsupported-plan specs.

**Commit checkpoint if authorized:** `feat(reminders): gate deferred touch materialization`

---

### Task 3: Add enrollment and occurrence-claim persistence

**Objective:** Persist plan assignment and exactly-once claims without creating future reminders.

**Files:**
- Create migration: `db/migrate/<timestamp>_create_touch_plan_enrollments.rb`
- Create migration: `db/migrate/<timestamp>_create_touch_occurrence_claims.rb`
- Create: `app/models/touch_plan_enrollment.rb`
- Create: `app/models/touch_occurrence_claim.rb`
- Modify associations: `app/models/account.rb`
- Modify associations: `app/models/reminder_group.rb`
- Modify associations only as needed: `app/models/reminder.rb`
- Tests: `spec/models/touch_plan_enrollment_spec.rb`
- Tests: `spec/models/touch_occurrence_claim_spec.rb`
- Factories: `spec/factories/touch_plan_enrollments.rb`, `spec/factories/touch_occurrence_claims.rb`

**Enrollment fields:**
- `account_id`
- polymorphic `remindable_type`, `remindable_id`
- optional `reminder_group_id`
- `status` (`active`, `paused`, `completed`, `cancelled`)
- immutable `plan_snapshot` JSONB
- `plan_version` or snapshot digest
- `next_due_at`
- `activated_at`
- `idempotency_key`
- `metadata` JSONB
- timestamps

**Occurrence claim fields:**
- `account_id`
- `touch_plan_enrollment_id`
- `step_key`
- `occurrence_key`
- `due_at`
- `status` (`claimed`, `materialized`, `skipped`, `failed`)
- optional `reminder_id`
- `claimed_at`, `materialized_at`
- `last_error`, `metadata`
- timestamps

**Required indexes/constraints:**
- due scan: `(status, next_due_at)` on enrollments;
- entity lookup: `(remindable_type, remindable_id, status)`;
- unique enrollment idempotency key scoped to account;
- unique `(touch_plan_enrollment_id, occurrence_key)`;
- unique non-null `reminder_id` on occurrence claims;
- foreign keys and account consistency validations.

**Steps:**
1. Write failing model/index/account-boundary specs.
2. Add only additive tables and indexes; do not alter `reminders` columns or statuses.
3. Validate migrations on an empty test DB and a copy with existing reminder rows.
4. Prove old reminder counts/statuses are unchanged after migrate.

**Commit checkpoint if authorized:** `feat(reminders): add deferred plan enrollment storage`

---

### Task 4: Introduce a backward-compatible plan application coordinator

**Objective:** Route new eligible applications to an enrollment while preserving the eager default and caller contracts.

**Files:**
- Create: `app/services/reminders/plan_application_service.rb`
- Create: `app/services/reminders/enroll_group_service.rb`
- Create: `app/services/reminders/plan_application_result.rb`
- Keep eager implementation: `app/services/reminders/apply_group_service.rb`
- Modify: `app/services/reminders/default_plan_service.rb`
- Modify: `app/controllers/api/v1/accounts/touch_plans_controller.rb`
- Modify: `app/services/automation_rules/touch_action_service.rb`
- Modify: `enterprise/lib/captain/tools/operations/touch_operations.rb`
- Review/update direct default-plan callers:
  - `app/services/scheduling/appointments/upsert_service.rb`
  - `app/services/crm/deals/upsert_service.rb`
  - `app/services/crm/tasks/upsert_service.rb`
- Tests: corresponding service, request, automation, and Captain specs.

**Steps:**
1. Define a result object with `execution_mode`, `touches`, and optional `enrollment` so all callers handle eager and deferred outcomes explicitly.
2. For feature disabled/unsupported entities, call existing `ApplyGroupService` byte-for-byte and return eager touches.
3. For eligible enabled accounts, snapshot normalized plan definitions and create one enrollment without creating reminders.
4. Preserve API compatibility: keep `data` as a touch array; for deferred application return an empty array and add `meta.execution_mode`, `meta.enrollment_id`, and `meta.next_due_at`.
5. Tag source metadata consistently for default plan, UI/API, automation, and Captain.
6. Do not enable task or conversation deferred behavior in this phase.

**Commit checkpoint if authorized:** `feat(reminders): enroll eligible touch plans for deferred execution`

---

### Task 5: Build deterministic schedule calculation and entity lifecycle sync

**Objective:** Derive due times from current appointment/deal data and keep enrollment caches current across every writer.

**Files:**
- Create: `app/services/reminders/enrollment_schedule_service.rb`
- Create: `app/services/reminders/sync_enrollment_service.rb`
- Create: `app/listeners/touch_plan_enrollment_listener.rb`
- Modify listener registration: `app/dispatchers/async_dispatcher.rb`
- Modify lifecycle handling as required:
  - `app/models/scheduling/appointment.rb`
  - `app/models/crm/deal.rb`
  - `app/services/scheduling/appointments/upsert_service.rb`
  - `app/services/crm/deals/upsert_service.rb`
  - `app/services/integrations/medelement/appointment_importer_service.rb`
  - `app/services/integrations/medelement/receptions_sync_service.rb`
- Tests: listener/service specs plus MedElement importer specs.

**Steps:**
1. Reuse `Reminder` relative anchor/timezone semantics rather than implementing a second date calculation formula.
2. Compute a stable `step_key` from the immutable plan snapshot and an `occurrence_key` from enrollment + step + intended anchor occurrence.
3. On appointment/deal timing changes, update only `next_due_at`; do not create a reminder.
4. On cancelled/completed/deleted entity, cancel/pause enrollment and skip open unmaterialized claims.
5. Ensure direct integration saves and cleanup paths emit/synchronize lifecycle state; do not rely solely on `UpsertService`.
6. Add tests for moved later, moved earlier but future, moved earlier past grace, cancelled, completed, destroyed, contact/route change, and concurrent update.

**Commit checkpoint if authorized:** `feat(reminders): sync deferred schedules with live entities`

---

### Task 6: Materialize due reminders safely from a minute job

**Objective:** Convert a due plan step into exactly one normal reminder immediately before delivery.

**Files:**
- Create: `app/jobs/reminders/materialize_due_enrollments_job.rb`
- Create: `app/services/reminders/materialize_enrollment_step_service.rb`
- Modify: `app/jobs/trigger_scheduled_items_job.rb` or `config/schedule.yml` (choose one enqueue point, not both)
- Reuse: `app/services/reminders/create_service.rb`
- Reuse unchanged: `app/jobs/reminders/process_pending_reminders_job.rb`
- Reuse unchanged: `app/jobs/reminders/execute_reminder_job.rb`
- Reuse unchanged: `app/services/reminders/execute_service.rb`
- Tests: `spec/jobs/reminders/materialize_due_enrollments_job_spec.rb`
- Tests: `spec/services/reminders/materialize_enrollment_step_service_spec.rb`
- Modify: `spec/jobs/trigger_scheduled_items_job_spec.rb`
- Modify: `spec/configs/schedule_spec.rb` if schedule changes.

**Steps:**
1. Select only `active` enrollments with `next_due_at <= Time.current`, account feature enabled, and `activated_at` at or before due time.
2. Batch with `FOR UPDATE SKIP LOCKED`; never load every appointment/deal each minute.
3. Re-read entity and recompute effective due time under the claim transaction.
4. If moved later, update `next_due_at` and create no claim/reminder.
5. If terminal/missing, cancel enrollment and create a skipped audit claim.
6. If past the 5-minute grace, create a skipped claim with `missed_due_to_reschedule` and do not send.
7. Insert occurrence claim using the unique key. On conflict, do nothing.
8. In the same DB transaction, create one normal `Reminder` through `Reminders::CreateService`, link it to the claim, and mark claim `materialized`.
9. Store enrollment/step/occurrence IDs in reminder metadata for audit.
10. Let the existing pending processor, execution guard, working-hours policy, materialized message idempotency, outbound queue, retries, and completion path deliver it.
11. Add stale `claimed` recovery that either links the transactionally created reminder or marks the claim failed; it must never send directly.
12. Add concurrency specs with two jobs and assert one claim, one reminder, and one outgoing message.

**Commit checkpoint if authorized:** `feat(reminders): materialize due touch occurrences exactly once`

---

### Task 7: Add final pre-send entity guard

**Objective:** Close the race between scheduler claim and actual message materialization.

**Files:**
- Modify: `app/services/reminders/execution_schedule_guard.rb`
- Modify only if needed: `app/services/reminders/execution_lock_service.rb`
- Modify: `spec/services/reminders/execution_schedule_guard_spec.rb`
- Modify: `spec/services/reminders/execute_service_spec.rb`

**Steps:**
1. For reminders linked to a deferred occurrence, reload enrollment and current remindable before message materialization.
2. Cancel when entity is missing, cancelled, completed, enrollment is paused/cancelled, or occurrence no longer matches current schedule.
3. Reschedule only when the effective time is still future.
4. Skip rather than send late when effective time is older than the configured grace window.
5. Preserve current behavior for every reminder not linked to a deferred occurrence.
6. Test the race: appointment/deal changes after claim but before execution, including delivery already materialized (must not cancel a provider-bound message).

**Commit checkpoint if authorized:** `fix(reminders): guard deferred touches against stale entities`

---

### Task 8: Make the deferred state native in UI/API

**Objective:** Let users see and cancel an assigned plan even though no future reminder rows exist.

**Files:**
- Modify API/payloads: `app/controllers/api/v1/accounts/touch_plans_controller.rb`
- Add enrollment endpoints only if needed: `app/controllers/api/v1/accounts/touch_plan_enrollments_controller.rb`
- Add policies/routes/serializers under existing outbound conventions.
- Modify API client: `app/javascript/dashboard/api/touchPlans.js`
- Modify entity surface: `app/javascript/dashboard/components-next/Outbound/EntityTouchesCard.vue`
- Modify plan page: `app/javascript/dashboard/routes/dashboard/campaigns/pages/OutboundTouchPlansPage.vue`
- Add ru/en/kk i18n under existing outbound locale files.
- Tests: request specs, component specs, and locale specs.

**Steps:**
1. Show active plan name, next trigger, entity anchor, and status `Ожидает триггера`.
2. Keep materialized reminders in the existing touch history.
3. Cancel enrollment separately from cancelling materialized reminders; define UI copy clearly.
4. Do not fabricate planned reminders in the API or Vue store.
5. Ensure existing eager accounts render exactly as before.

**Commit checkpoint if authorized:** `feat(outbound): show deferred touch plan enrollments`

---

### Task 9: Observability, shadow mode, and operational safety

**Objective:** Prove scheduler correctness before any customer uses it.

**Files:**
- Add structured logging/metrics in new enrollment/materialization services.
- Add read-only audit rake task: `lib/tasks/reminders.rake` or a focused service invoked by `rails runner`.
- Update worker topology only if a new queue is introduced; prefer existing `scheduled_jobs` and `outbound_messages` queues.
- Internal docs change belongs in the docs repo/submodule and must follow `docs/AGENTS.md`.

**Required metrics/log fields:**
- account ID, enrollment ID, entity type/ID, step key, occurrence key;
- due/materialized/skipped/conflict/error counts;
- scheduler lag (`now - due_at`);
- duplicate-claim conflicts;
- stale-claim recovery;
- cancellation/missed reasons;
- reminders created by deferred mode.

**Shadow rollout:**
1. Deploy additive migrations and disabled code only.
2. In shadow mode for a DEV account, calculate due decisions but create neither claims nor reminders.
3. Compare shadow decisions against current eager reminders for appointment/deal plans.
4. Require zero unexpected recipient/time/content differences over a representative window.
5. Enable real deferred mode only for newly applied plans in DEV.
6. Run browser/API/DB live checks.
7. Obtain explicit approval before any PROD feature enablement.

**Commit checkpoint if authorized:** `chore(reminders): add deferred execution observability`

---

### Task 10: Verification and PROD rollout gates

**Objective:** Ship without breaking in-flight production touches.

**Code-level checks:**
- Targeted RSpec for all new/changed services, jobs, models, requests, integrations, automation, Captain, and current reminder execution.
- Targeted Vitest/ESLint for modified outbound UI.
- RuboCop on changed Ruby files.
- `bundle exec rails db:migrate:status` and migration rollback/forward on a disposable DB.
- `git diff --check` and exact-final independent review.

**DEV/live evidence:**
1. Capture read-only baseline counts by reminder status and remindable type.
2. Create a fresh test appointment/deal after feature enablement; confirm enrollment exists and no reminder exists before due.
3. Move it later; confirm `next_due_at` changes and no old reminder appears.
4. Move it earlier within grace; confirm exactly one reminder/message.
5. Move it earlier outside grace; confirm skipped claim and no message.
6. Cancel/delete entity; confirm no reminder/message.
7. Run two materializer jobs concurrently; confirm one occurrence claim, one reminder, one message.
8. Disable feature; confirm no new materialization while old eager reminders still execute.

**PROD preflight (read-only):**
- Count existing open reminders by status/type/group and save the audit output under `/root/crafty/logs/`.
- Confirm no pending migrations and all required workers/queues are healthy.
- Confirm feature disabled for every account.

**PROD rollout (requires explicit approval):**
1. Run `db:chatwoot_prepare` before app/worker recreation.
2. Deploy code with feature disabled.
3. Verify existing reminder counts and scheduled worker health are unchanged.
4. Enable only one pilot account and only for newly applied appointment/deal plans.
5. Monitor scheduler lag, occurrence conflicts, failure rate, and old reminder delivery.
6. Expand account by account only after a successful observation window.

**Rollback:**
- Disable the account feature immediately.
- Do not delete enrollments or occurrence claims.
- Existing reminders, including any already materialized by deferred mode, continue through the old delivery pipeline.
- If needed, pause only active enrollments; never cancel unrelated pre-existing reminders.
- Revert application code only after feature disablement; additive tables may remain safely unused.

---

## Why this is native, logical, and reliable

- **Native:** Uses account feature flags, ActiveRecord, ActiveJob/Sidekiq, PostgreSQL constraints, existing reminder services, existing delivery queues, and existing Vue outbound surfaces.
- **Logical:** Separates `plan enrollment` (future intent) from `Reminder` (a due delivery occurrence) without duplicating channel delivery logic.
- **Reliable:** Exactly-once is enforced by a database claim before delivery; external sends remain behind the existing materialized-message idempotency and retries.
- **Production-safe by design:** The default path remains eager, old rows are never migrated, and the new job sees only explicitly created enrollments for enabled accounts.

## Known risks and mitigations

| Risk | Mitigation |
|---|---|
| Duplicate cron workers | Unique occurrence index + transaction + `SKIP LOCKED` |
| Crash after claim | Claim and reminder created transactionally; stale-claim recovery |
| Crash/provider retry | Existing processing claim and materialized-message idempotency |
| Appointment/deal moved | Event sync plus final pre-send guard |
| Integration bypasses UpsertService | Central listener and explicit integration tests |
| Plan edited after assignment | Immutable normalized `plan_snapshot` |
| Scheduler downtime | Indexed due backlog, lag metric, grace/missed policy |
| Working hours | Existing `DeliveryWindowPolicy` after reminder materialization |
| Existing PROD touches affected | Feature disabled by default; old reminders excluded by schema/query |
| API/UI confusion | Explicit enrollment payload/status; no fake future reminders |

## Open product decisions before implementation

1. Grace window for a trigger moved into the past: recommended 5 minutes.
2. Whether `completed` entities always cancel unmaterialized future steps: recommended yes for pre-visit/pre-deal notifications.
3. Whether users may edit a plan enrollment after assignment or only cancel/reapply: recommended cancel/reapply initially.
4. Initial scope: recommended appointments and deals only; tasks/conversations/recurrence later.
5. Pilot account and minimum observation window before wider PROD rollout.
