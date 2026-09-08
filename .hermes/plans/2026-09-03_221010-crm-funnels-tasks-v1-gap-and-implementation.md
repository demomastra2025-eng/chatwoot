# CRM «Воронки и задачи» v1 — Gap Analysis and Implementation Plan

> **For Hermes:** Реализовывать последовательно, не начиная следующий этап до проверки инвариантов предыдущего. Commit/push/deploy — только после отдельного разрешения пользователя.

**Goal:** Довести существующий CRM-модуль OneLink до минимально корректного продуктового ядра из ТЗ, не переписывая уже работающие Pipeline/Stage/Deal/Task, не ломая интеграции и не таща P1/P2 в первый релиз.

**Architecture:** Эволюция текущего Rails/Vue CRM. Сохраняем существующие bigint ID, account scope, custom fields, configurable task statuses, reminders и AutomationRule. Добавляем недостающие доменные команды, корректную date-only семантику, StageVisit, усиленный EventLog, next action/waiting и затем строим UX/аналитику поверх этих фактов.

**Tech Stack:** Rails 7.1, PostgreSQL, Vue 3, Vite, Pundit, ActiveJob/Sidekiq, существующие `Crm::*`, `AutomationRule`, `Reminder`, ActionCable.

---

## 1. Решения по объёму

### Точно делаем в первом контуре (P0)

1. Настоящую семантику `timed / all-day / unscheduled` без искусственного времени для all-day.
2. Прямую связь Task → Deal как обязательную для sales-task, сохранив standalone/personal task через явный `context_kind`; nullable `deal_id` не должен оставаться неоднозначной классификацией.
3. Один assignee у Task и один owner у Deal; не объединяем эти роли.
4. Отдельные lifecycle-команды Deal и Task с optimistic locking, стабильными domain error codes и idempotency там, где возможен повтор.
5. Полноценные факты переходов: `Crm::Event` как append-only envelope и `Crm::StageVisit` для времени на этапах.
6. `next_action` и `waiting` как единый серверный контракт.
7. Required-on-enter для этапов, Won/Lost/Reopen и явную политику открытых задач при закрытии сделки.
8. Настраиваемые типы задач и результаты поверх текущих `activity_type/outcome`, с совместимым переходным периодом.
9. Быстрые сценарии: task из deal, completion/outcome, reschedule, cancel/reopen, drag с rollback/Undo.
10. Уже существующие Board/List/Calendar не переписываем, а доводим до общего серверного контракта.
11. Минимальную доверенную аналитику: текущее состояние, фактические переходы, время этапа, task discipline, no-next-action, drill-down.
12. Account/row/command scope, keyboard/touch и локализованные ru/en/kk состояния ошибок.

### Делаем позже (P1)

- recurring tasks;
- Google/Microsoft/Apple external calendar sync;
- observers/guests при одном ответственном;
- saved views team/workspace, расширенные bulk operations;
- business-hours SLA и capacity;
- forecast snapshots и weighted forecast как официальный исторический отчёт;
- historical team membership;
- pipeline transfer templates и merge справочников;
- расширенная telemetry UX и отдельная аналитическая витрина/warehouse, если объём данных этого потребует.

### Точно не делаем в этом модуле

- миграцию bigint → UUID: стоимость и риск не дают пользовательской ценности;
- переименование внутреннего API namespace `/api/.../crm/*`: пользователь его не видит, а совместимость важнее; пользовательские dashboard URL при этом переводим на `/deals` и `/tasks`;
- удаление существующих настраиваемых статусов задач: сохраняем их как display/workflow layer, но вводим стабильные canonical categories;
- несколько исполнителей одной задачи;
- подзадачи, зависимости, Gantt и project-management semantics;
- произвольный BPMN, пользовательский код и marketplace scripts;
- AI scoring/next-best-action в P0;
- копирование визуального дизайна amoCRM/Bitrix/Pipedrive;
- Sankey как обязательный P0: сначала проверяемая таблица переходов и drill-down;
- новый отдельный automation engine: усиливаем существующие `AutomationRule`, CRM listeners и idempotency.

## 2. Что уже есть и переиспользуется

- Models: `app/models/crm/pipeline.rb`, `stage.rb`, `deal.rb`, `task.rb`, `task_status.rb`, `event.rb`, `field_definition.rb`.
- Commands/services: `app/services/crm/deals/transition_service.rb`, `upsert_service.rb`; `app/services/crm/tasks/status_transition_service.rb`, `upsert_service.rb`; `app/services/crm/base_write_service.rb`.
- Audit/timeline: `app/services/crm/events/writer.rb`, `app/services/crm/timelines/*`.
- Board ordering: `app/services/crm/board_positioner.rb`.
- UI: `CrmDealsPage.vue`, `CrmTasksPage.vue`, `CrmDealBoard.vue`, `CrmTaskBoard.vue`, `CrmTaskCalendar.vue`, task/deal drawers and timeline.
- Existing views: Deal Board/List; Task Board/List/Calendar.
- Existing automation integration: `AutomationRule`, `CrmAutomationRuleListener`, `AutomationRules::CrmActionService` and action idempotency infrastructure.
- Existing reminders/touches: `Reminder` and `app/services/reminders/*`.
- Existing reports: `Crm::Reports::FunnelsService`, `ManagerEffectivenessService`.
- Existing permissions: `Crm::*Policy`, account role permissions.

## 3. Главные gaps текущей реализации

1. `all_day=true` пока сочетается с `due_at` в условном полудне; это timezone-dependent surrogate, а не date-only.
2. `activity_type` и outcomes — hardcoded enums/maps, нет account-scoped TaskType/TaskOutcome catalog и inline «Другой».
3. Task lifecycle частично выражен через configurable status, но нет отдельных `reschedule/cancel/reopen/assign/complete` contracts и причинности.
4. `crm_events` хранит только `event_type/meta/actor/time`; нет явных source, before/after, correlation/causation/schema version и DB append-only guard.
5. `StageVisit` отсутствует; историческое время этапа сейчас нельзя воспроизвести надёжно.
6. Required fields проверяются при закрытии, но не как stage-specific required-on-enter contract для любого перехода.
7. Нет полного `waiting_until/reason` и единого серверного `next_action/health`.
8. Закрытие сделки не имеет завершённой атомарной политики cancel открытых tasks с общей correlation.
9. Analytics в основном считает по текущим таблицам/датам, а не по фактическим visits/events; исторические переходы и reopen ненадёжны.
10. Scope прав крупный (`view/manage`), а own/team/all и field/command-level capabilities неполны.
11. Drag/drop существует, но нужны единые optimistic rollback, conflict response и compensating Undo.
12. Pipelines/stages и связанные с сущностями events сейчас могут физически удаляться в отдельных путях; исторические справочники и факты требуют archive-only semantics.
13. Task list загружает весь отфильтрованный набор и пагинирует в браузере; P0 нужна ограниченная серверная пагинация.
14. Reports смешивают неизвестную сумму (`NULL`) с реальным нулём; data-quality и денежные метрики должны различать их.

---

## 4. Последовательность реализации

### Task 0: Зафиксировать baseline и compatibility contract

**Objective:** Не смешать новый CRM scope с текущим большим dirty tree и не сломать API/automation/Captain consumers.

**Files:**
- Inspect: `app/controllers/api/v1/accounts/crm/*`
- Inspect: `app/services/crm/**/*`
- Inspect: `app/services/automation_rules/crm_*`
- Inspect: `enterprise/app/services/captain/tools/**/*deal*`
- Inspect: `swagger/paths/index.yml`, `swagger/swagger.json`
- Modify: `app/javascript/dashboard/routes/dashboard/crm/routes.js` and all generated dashboard links/helpers that point to CRM pages.
- Create: `docs/internal/crm-v1-compatibility.mdx` (в docs submodule, отдельным docs commit только после разрешения)

**Steps:**
1. Снять таблицу current API fields/commands/events and consumers.
2. Разделить текущие dirty изменения на CRM-related и unrelated, ничего не откатывая.
3. Зафиксировать compatibility aliases: `activity_type`, `outcome`, `all_day`; основные пользовательские dashboard routes сделать `/deals` и `/tasks`, а старые `/crm/deals` и `/crm/tasks` оставить redirect-only для закладок/deep links. Внутренние API routes `/api/v1/accounts/:account_id/crm/*` сохранить.
4. Определить feature flags по account для каждого несовместимого UI switch.
5. Утвердить продуктовые решения из раздела 1 до миграций.

**Verification:** read-only contract matrix; `git diff --check`; подтверждение владельцем продукта.

### Task 1: Исправить date-only модель задач до PROD

**Objective:** All-day task хранит календарную дату и не меняет день между timezone.

**Files:**
- Create migration: `db/migrate/<timestamp>_add_date_only_schedule_to_crm_tasks.rb`
- Modify: `app/models/crm/task.rb`
- Modify: `app/services/crm/tasks/upsert_service.rb`
- Modify: `app/services/crm/payload_builder.rb`
- Modify: `app/controllers/api/v1/accounts/crm/tasks_controller.rb`
- Modify: `app/javascript/dashboard/routes/dashboard/crm/pages/CrmTasksPage.vue`
- Modify: `app/javascript/dashboard/routes/dashboard/crm/taskTimeBuckets.js`
- Modify: `app/javascript/dashboard/components-next/CRM/CrmTaskCalendar.vue`
- Modify: `app/javascript/dashboard/components-next/Scheduling/SchedulingVueCalCalendar.vue`
- Tests: corresponding model/service/request/Vitest specs.

**Contract:**
- Canonical states: `unscheduled` = `due_at/due_on NULL`; `timed` = `due_at`, `due_on NULL`; `all_day` = `due_on DATE`, `due_at NULL`.
- Store `schedule_timezone` for business context.
- Keep `all_day` and old API fields temporarily as compatibility adapter; stop generating noon timestamps.
- Backfill only records explicitly marked `all_day=true`, converting date in stored/task/account timezone; emit migration report.

**TDD steps:**
1. Add failing model/request tests for cross-timezone same-date behavior and XOR invariant.
2. Add schema and compatibility serializer.
3. Update bucketing, filtering, calendar drag and form payload.
4. Test timed→all-day, all-day→timed, date move and unscheduled.
5. Verify DST/timezone fixtures and DEV API round-trip.

### Task 2: Сделать CRM events проверяемыми фактами

**Objective:** История переходов и задач воспроизводима и пригодна для аналитики/Undo.

**Files:**
- Create migration: `db/migrate/<timestamp>_extend_crm_events_for_domain_facts.rb`
- Modify: `app/models/crm/event.rb`
- Modify: `app/services/crm/events/writer.rb`
- Modify: `app/services/crm/timelines/base_service.rb`
- Modify all writers under `app/services/crm/deals/` and `app/services/crm/tasks/`.
- Tests: `spec/models/crm/event_spec.rb`, `spec/services/crm/events/writer_spec.rb`, existing transition/upsert specs.

**Contract additions:** `source`, `before_data`, `after_data`, `correlation_id`, `causation_id`, `schema_version`, actor kind/id, command/idempotency key and durable publication state where applicable. `crm_events` becomes the source/outbox for CRM side effects; не создаём вторую конкурирующую таблицу событий.

**Steps:**
1. Test stable event envelope and PII-safe payload.
2. Add nullable columns and indexes first; dual-write old `meta` compatibility.
3. Make ordinary update/destroy of persisted events unavailable in application code; remove entity `dependent: :destroy_async` behavior for historical facts. Correction is a compensating event.
4. Add event names for rescheduled/completed/cancelled/reopened/assigned/waiting.
5. Publish events after commit through an idempotent job; add retry/replay for unpublished rows and dedupe by event/action.
6. Verify automation listeners still receive legacy-compatible names/payloads.

### Task 3: Ввести StageVisit и reconciliation

**Objective:** Каждый фактический вход/выход из этапа хранится атомарно с переходом Deal.

**Files:**
- Create migration: `db/migrate/<timestamp>_create_crm_stage_visits.rb`
- Create: `app/models/crm/stage_visit.rb`
- Modify: `app/models/crm/deal.rb`, `app/models/crm/stage.rb`, `app/models/crm/pipeline.rb`
- Modify: `app/services/crm/deals/transition_service.rb`, `upsert_service.rb`
- Create: `app/services/crm/stage_visits/reconciliation_service.rb`
- Create: `app/jobs/crm/stage_visits/reconcile_job.rb`
- Tests: model, transition concurrency, backfill and reconciliation specs.

**Steps:**
1. Test one active visit maximum per Deal (partial unique index).
2. Create initial visit atomically on Deal create.
3. Lock Deal + active visit; close old/open new in the same transition transaction.
4. Archive pipelines/stages/entities instead of deleting referenced historical dictionaries or events.
5. Snapshot stage/pipeline name/category and correlation.
6. Backfill one synthetic active visit per existing Deal with `estimated=true` and `reliable_since` report; never fabricate unknown intermediate stages.
7. Run reconciliation report-only first; auto-fix only safe derived inconsistencies.

### Task 4: Единый Deal transition contract

**Objective:** Open/Won/Lost/Reopen/reorder имеют разные явные команды и не обходятся PATCH/Captain/automation.

**Files:**
- Modify: `config/routes.rb`
- Modify: `app/controllers/api/v1/accounts/crm/deals_controller.rb`
- Modify: `app/services/crm/deals/transition_service.rb`
- Create: `app/services/crm/deals/close_won_service.rb`
- Create: `app/services/crm/deals/close_lost_service.rb`
- Create: `app/services/crm/deals/reopen_service.rb`
- Create: `app/services/crm/deals/reorder_service.rb`
- Modify: Captain deal tools and AutomationRules CRM action path to call the same services.
- Update Swagger and request/service/tool specs.

**Steps:**
1. Add stable error codes and canonical conflict response with current snapshot/version. Reuse of an idempotency key with a different normalized body returns `IDEMPOTENCY_KEY_REUSED`, not the old result.
2. Separate reorder from stage transition; reorder must not touch visit duration.
3. Enforce one Won/Lost per pipeline at DB/domain boundary without rewriting existing IDs.
4. On close, cancel eligible open tasks in the same correlation; preserve exceptions only by explicit policy.
5. Reopen creates a new visit and does not silently reopen old tasks.
6. Implement compensating Undo for recent transition, not event deletion.

### Task 5: Stage rules and required-on-enter

**Objective:** Переход проверяет только реально необходимые данные целевого этапа для UI/API/automation/Captain одинаково.

**Files:**
- Create migration/model/controller for `crm_stage_field_requirements`.
- Modify: `app/models/crm/stage.rb`
- Modify: `app/services/crm/required_fields_inspector.rb`
- Modify: `app/services/crm/deals/transition_service.rb`
- Modify: pipeline settings controller/UI and `CrmClosingReasonDialog.vue` or a new compact missing-fields panel.
- Tests: stage rules requests, transition service, Vue panel/error mapping.

**Steps:**
1. Support `field_key`, required, validation JSON, optional role exemptions.
2. Validate all entry paths server-side.
3. Add pipeline policies `restrict_stage_skipping` and `restrict_backward_move` only if user enables them.
4. Return structured missing fields; UI opens only those fields.
5. Keep Lost reason as structured close command; do not model each loss reason as a stage.
6. Manager/admin override, where product policy permits it, requires reason and emits an audit event.

### Task 6: Waiting and canonical next action

**Objective:** Deal всегда имеет однозначное состояние следующего действия: task, waiting, expired waiting or no action.

**Files:**
- Create migration: waiting fields on `crm_deals`.
- Create: `app/services/crm/deals/set_waiting_service.rb`, `clear_waiting_service.rb`, `next_action_service.rb`.
- Modify: `app/services/crm/payload_builder.rb`.
- Modify: Deal API routes/controller.
- Modify: `CrmDealBoard.vue`, `CrmDealTasksPanel.vue`, `CrmDealsPage.vue`.
- Tests: service/request/payload/board specs.

**Steps:**
1. Implement one server-side sorting algorithm for overdue/today/future date-only/timed tasks.
2. Do not duplicate `next_task_*` into writable Deal columns; return derived/read-model payload.
3. Implement waiting with until + required reason + optional wake-up Task.
4. Add system filters: overdue, no action, waiting expired.
5. Recalculate/broadcast after task lifecycle, waiting and deal close/reopen.
6. Add grace only to notifications, not to visible health.

### Task 7: TaskType/TaskOutcome catalog with compatibility

**Objective:** Types/outcomes become configurable without breaking current API, automations and historical tasks.

**Files:**
- Create migrations/models: `crm_task_types`, `crm_task_outcomes`; add `task_type_id`, `task_outcome_id` to tasks.
- Modify: `app/models/crm/task.rb`, account associations/bootstrap.
- Modify: task controllers, payload builder, field catalog and AutomationRules catalog/actions.
- Create frontend API/store and reusable TaskType picker.
- Modify: `CrmTasksPage.vue`, `CrmTaskCompletionDialog.vue`, Deal task quick-create UI.
- Tests across model/service/request/Vue/automation/Captain.

**Steps:**
1. Add explicit task `context_kind` (`sales`/`personal`): sales requires `deal_id`; personal may omit it. Backfill deterministically and report ambiguous/orphan records.
2. Seed mappings for current task/call/meeting/message/touch codes and outcomes.
3. Preserve current string fields as compatibility snapshots during rollout.
4. Validate outcome belongs to selected type; archived values remain readable.
5. Implement inline «Другой» for users with settings permission.
6. Apply defaults precedence without overwriting manually changed due/duration/reminder.
7. Switch consumers, measure legacy field use, remove aliases only in a later breaking version.

### Task 8: Explicit Task lifecycle commands

**Objective:** Completion, cancellation, reopen, reschedule and assignment cannot be confused with generic PATCH/status movement.

**Files:**
- Create services: `app/services/crm/tasks/{complete,cancel,reopen,reschedule,assign}_service.rb`.
- Modify routes/controller/API client.
- Modify `CrmTaskCompletionDialog.vue`, `CrmTasksPage.vue`, `CrmTaskBoard.vue`, `CrmTaskCalendar.vue`.
- Modify reminders sync/cancel integration.
- Tests: service/request/calendar/list/board specs.

**Steps:**
1. Introduce canonical categories including `cancelled`; retain configurable statuses as display workflow.
2. Complete records server `completed_at` and `completed_by`; never overwrite due.
3. Cancel requires reason and is excluded from completion metrics.
4. Reschedule emits before/after and recalculates reminders.
5. Assign validates account/deal access and emits notification once.
6. Reopen clears current terminal fields but preserves immutable history.
7. Idempotency protects double-click/retry.
8. Separate task notification/reminder semantics from outbound touch plans: ordinary user Task must not silently enroll into client messaging automation unless an explicit plan/rule requests it.

### Task 9: Enforce own/team/all and command capabilities on the server

**Objective:** Фильтр интерфейса не является защитой; list/show/report/drill-down и lifecycle-команды используют один scope contract.

**Files:**
- Modify: `app/policies/crm/base_policy.rb`, `deal_policy.rb`, `task_policy.rb` and their scopes.
- Modify CRM controllers/report services to consume policy scopes rather than account-wide relations.
- Modify permission constants/settings UI only after backend capabilities exist.
- Tests: policy specs plus request specs for list/show/export/report/transition/assign/complete.

**Steps:**
1. Define capabilities separately: view, manage fields, assign, transition/complete, configure, export.
2. Define scopes: own, team, all; specify unassigned records explicitly.
3. Apply scope to every record lookup, aggregate and drill-down—not only index filters.
4. Check assignee/owner target eligibility on every assignment command.
5. Add bounded server pagination/cursors and count metadata for Tasks; UI must not fetch the whole account dataset for local pagination.
6. Add cross-account and cross-team denial tests before frontend controls.
7. Render controls from capabilities, but keep server denial authoritative.

### Task 10: Finish P0 UX without rewriting screens

**Objective:** Existing Board/List/Calendar become fast, reversible and accessible.

**Files:** Existing CRM pages/components and focused new reusable pickers/panels under `components-next/CRM/`.

**Steps:**
1. Quick Task from Deal: prefill deal, owner→assignee, type, schedule; title autofocus; Enter submit.
2. Add schedule presets Today/Tomorrow/Week/Choose and visible resulting local value.
3. Drag/reorder: optimistic placeholder, exact rollback, structured validation panel, retry and Undo.
4. Calendar: timed resize/move, all-day strip, timed↔all-day preview, conflict rollback.
5. Preserve URL filters/view and local user preference. Canonical dashboard URLs: `/app/accounts/:account_id/deals` and `/app/accounts/:account_id/tasks`; old `/crm/deals` and `/crm/tasks` redirect with the complete query string and deep-link parameters.
6. Add keyboard move alternative and touch long-press; honor reduced motion.
7. Keep cards compact: primary fields + max two configured secondary fields.

**Verification:** focused Vitest, browser walkthrough on DEV for mouse/keyboard/touch width, API/log proof, no console errors.

### Task 11: Minimal trustworthy analytics

**Objective:** Report only metrics supported by StageVisit/Event facts; do not overclaim historical precision.

**Files:**
- Refactor `app/services/crm/reports/funnels_service.rb`.
- Extend/add task discipline and data-quality report services/controllers.
- Modify analytics Vue pages/components and Swagger.
- Tests with explicit synthetic timelines and access scopes.

**P0 reports:**
- current count/amount by stage and currency, preserving unknown amount separately from real zero;
- factual transition table and stage visits/time median/P75;
- closed win rate with explicit date basis;
- overdue/today/future/no-action/waiting coverage;
- task completed/cancelled/on-time/lag/reschedule by type/assignee;
- data quality + drill-down.

**Not in this task:** warehouse, Sankey, predictive score, attribution, historical team membership, official forecast snapshots.

### Task 12: Harden existing automation and rollout

**Objective:** Existing AutomationRule uses the new domain commands safely, without a second engine.

**Files:** `CrmAutomationRuleListener`, `AutomationRules::CrmActionService`, execution/action runner, CRM event dispatch, reconciliation/observability, feature flags, docs.

**Steps:**
1. Route CRM actions through canonical services.
2. Use event/correlation + rule/version + action index as dedupe key.
3. Publish/replay undelivered `crm_events`; tolerate at-least-once execution without duplicate side effects.
4. Limit chain depth/cycles; expose final failures without rolling back original successful command.
5. Roll out by account/team/pipeline flags: facts → commands → UI → analytics.
6. DEV migration + shadow checks; pilot one account; compare counts and errors.
7. PROD only after explicit approval, migration prerequisite and rollback evidence.

---

## 5. Test and evidence matrix

### Backend
- Model constraints and account isolation.
- Service specs for every lifecycle command, rollback, idempotency and conflict.
- Request specs for canonical response/error schemas.
- Concurrency specs: double transition, complete-vs-reschedule, archived target.
- Migration/backfill/reconciliation fixtures with legacy records.
- Automation/Captain contract tests proving shared services.

### Frontend
- Unit tests for date semantics, next-action rendering and structured errors.
- Component tests for quick create, required-fields panel, outcome flow and Undo.
- DnD tests for optimistic success, 409/422 rollback and disappearing-column regression.
- Calendar timed/all-day conversion tests.
- Keyboard/touch and basic a11y assertions.

### DEV/live
- Fresh migrations and schema checks.
- Real API round-trips in isolated DEV records.
- Browser walkthrough with network/console/log evidence.
- ActionCable refresh and event/timeline proof.
- Reconciliation report with zero unexplained critical mismatches.

### PROD
- No mutation until explicit authorization.
- Preflight migration status, backup/rollback and affected-record counts.
- Targeted deploy, health, external API proof and post-deploy reconciliation.

## 6. Gates before starting

1. Product owner accepts the scope decisions, especially:
   - keep bigint IDs;
   - keep configurable TaskStatus UI, add canonical categories;
   - convert current all-day implementation to real `due_on DATE` before PROD;
   - use `/deals` and `/tasks` as canonical user-facing dashboard URLs; preserve old `/crm/*` only as redirects and keep internal API namespace stable;
   - analytics P0 is factual table/drill-down, not full BI suite.
2. Current CRM dirty changes are reviewed/frozen so this work does not overwrite parallel WIP.
3. Decide pilot account/team and whether current DEV data can be backfilled/reconciled.
4. Approve implementation order: Task 1 first, then facts/visits, then lifecycle/next-action, then UX, analytics and automation.

## 7. Recommended delivery slices

- **Slice A — 1–2:** correct date-only + event envelope.
- **Slice B — 3–5:** StageVisit + canonical Deal transitions + stage requirements.
- **Slice C — 6:** waiting + next action.
- **Slice D — 7–8:** configurable types/outcomes + Task lifecycle.
- **Slice E — 9:** server-enforced permissions.
- **Slice F — 10:** UX completion and accessibility.
- **Slice G — 11–12:** trustworthy analytics + hardened automation + rollout.

Each slice receives its own scoped tests, exact diff review, DEV evidence and explicit go/no-go before the next slice.
