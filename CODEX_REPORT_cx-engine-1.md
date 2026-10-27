# cx-engine-1 implementation report

Branch: `codex/cx-engine-1`. Base: `3d77ef5701548999166e28c73753f10a27806bf8`. No remote, production system, or customer data was accessed. No migration or schema change was made.

## Changes and decisions

- **G3:** Appointment updates now re-time every editable, visit-anchored automation reminder after commit, including materialized deferred reminders. The existing `Reminders::MissedAutomationTouchPolicy` is the single decision for late, started, and closed visits, with one five-minute grace constant shared by the send guard and deferred materializer. The send guard rechecks the live visit after schedule refresh. Per-reminder savepoints and exception tracking let other reminders continue if one fails. MedElement reconciliation leaves running reminders alone while still closing before-visit reminders for terminal visits. I removed the former MedElement-only restriction because all appointment sources can move a visit and the deferred path already treats all sources alike. Manual reminders and terminal-event notices/follow-ups retain their existing behavior.
- **G1:** Creating or activating an active `appointment_created` rule enqueues the existing backfill job. Its service now exposes `plan`, selects every future nonterminal matching visit, and executes visit-timed actions through `AppointmentActionService`, including direct confirmation actions. It skips past or ineligible steps using the shared schedule probe and missed policy. The existing locks, provenance, and deduplication remain in use; a retried run does not create another open step.
- **G-off:** Deactivation, deletion, and removal of a `create_touch` action synchronously cancel editable reminders attributable to that rule or action. Existing enrollment cancellation remains in use. Delivered and delivery-materialized reminders are left alone. Reactivation uses G1 to plan future steps again.
- **G2:** Service name is no longer a default template binding or a default pack option. Surplus variables remain unbound until staff select a field. Fill statistics resolve appointment fields through the same `FieldReferences::RendererService` used at delivery. A field blocks when at least one upcoming matching visit is empty and the empty share is **10% or higher**; zero upcoming visits never block. The account-scoped read endpoint, rule validation, reminders page, and generic template editor use this result. Rule validation runs for active creation, activation, or a change to the set of template field references, so unrelated edits of older rules stay possible. Staff warnings and validation messages were added in Russian, Kazakh, and English, without placeholder values for empty fields.
- **G4:** `AutomationTouchInput` was the rule-editor path emitting a stale override flag; the drawer also preserves a flag for direct reminder edits. Event-rule actions now drop `manual_schedule_override` whenever `scheduled_at` is blank, for hash and array params and every timing mode, and the model validates the invariant. A real `scheduled_at` retains its explicit override. The API and clone path pass through this model normalization.
- **TZ:** Appointment-event action timezones normalize to `account.workspace_working_hours_timezone` on save. The resolved zone is exposed in the existing account payload, and the reminders page and both touch editors use it instead of the browser zone. The reporting/CRM timezone was not used.
- **Release tasks:** `lib/tasks/onelink_notifications.rake` supplies `retime_open`, `cancel_inactive_rule_reminders`, `backfill_rule`, and `normalize_rules`. They preview by default using IDs and counts only. Apply requires `APPLY=1 CONFIRM=yes BACKUP_DIR=<existing directory>` and writes a JSON backup of affected reminder IDs with old status, schedule, and error before changing them. The tasks call the same runtime services. They were not run against production.

The `docs/` submodule is uninitialized in this local clone (`git submodule status docs` reports a leading `-`), and this task forbids adding a remote. No documentation submodule commit was possible here.

## Scenario review and spec coverage

| Scenario | Coverage |
| --- | --- |
| 141336: a two-hour reminder is claimed, then the visit moves earlier and starts | `spec/services/reminders/execution_schedule_guard_visit_spec.rb`; save-time cancellation in `spec/services/reminders/retime_visit_touches_service_spec.rb` |
| Rule 59 style blank time and override is saved again | `spec/models/automation_rule_appointment_notifications_spec.rb`; API path in `spec/requests/api/v1/accounts/automation_rules_appointment_notifications_spec.rb` |
| Existing active rule is switched on for all future visits, none past | `spec/services/reminders/backfill_automation_rule_enrollments_service_notifications_spec.rb`; `spec/jobs/reminders/backfill_automation_rule_enrollments_job_spec.rb` |
| Rule is toggled off and on twice | `spec/services/reminders/backfill_automation_rule_enrollments_service_notifications_spec.rb`; `spec/services/reminders/cancel_rule_touches_service_spec.rb` |
| MedElement moves a confirmed visit to another day | `spec/services/integrations/medelement/appointment_importer_service_notifications_spec.rb`; the later confirmation-reset branch itself is outside this base |
| Two visits are imported in one sync tick without cross-effect | `spec/services/integrations/medelement/appointment_importer_service_notifications_spec.rb` |
| A deferred enrollment and its materialized reminder move together | `spec/services/reminders/retime_visit_touches_service_spec.rb`; `spec/services/reminders/materialize_enrollment_step_service_visit_spec.rb` |

Other new backend specs: `spec/models/scheduling/appointment_retime_spec.rb`, `spec/models/automation_rule_appointment_field_fill_spec.rb`, `spec/requests/api/v1/accounts/scheduling/appointment_field_fill_spec.rb`, `spec/services/scheduling/template_field_fill_stats_spec.rb`, and `spec/services/reminders/notifications_release_service_spec.rb`. Existing backend specs changed: `spec/services/reminders/missed_automation_touch_policy_spec.rb` and `spec/jobs/reminders/backfill_automation_rule_enrollments_job_spec.rb`.

Frontend specs added: `app/javascript/dashboard/helper/specs/appointmentFieldFill.spec.js` and `app/javascript/dashboard/components-next/whatsapp/WhatsAppTemplateParser.appointment.spec.js`. Frontend specs changed: `appointmentTemplatePresets.spec.js`, `SchedulingRemindersPage.spec.js`, `AutomationTouchInput.spec.js`, and `TouchEditorDrawer.errors.spec.js` in their existing dashboard directories.

## Checks run

| Check | Result |
| --- | --- |
| `pnpm install --frozen-lockfile` | Passed; `node_modules` was initially absent. |
| `ruby -c` over all 32 changed `.rb`/`.rake` files | Passed: 32 files, 0 failures. |
| `bundle exec rubocop` over all 32 changed Ruby files | Failed on eight pre-existing offenses in `app/models/scheduling/appointment.rb`. The same eight were verified on the base file using `git show` and RuboCop `--stdin`. None is on a changed line. |
| `bundle exec rubocop` over the other 31 changed Ruby files | Passed: 31 files, 0 offenses. The release service had three indentation offenses during development; these were corrected and its three-file focused check passed. |
| `pnpm exec eslint --quiet` over every changed `.js`/`.vue` file | Passed. An intermediate page-spec formatting failure was corrected, then checked again. |
| `pnpm exec prettier --check` over every changed `.js`/`.vue`/`.json` file | Passed. An intermediate page-spec formatting failure was corrected, then checked again. |
| `pnpm exec vitest run` for the seven affected existing frontend suites | Passed: 7 files, 73 tests. |
| `pnpm exec vitest run` for the new parser warning spec | Passed: 1 test. Its initial run failed because the assertion ran before Vue mounted; awaiting `nextTick` fixed the test. |
| `pnpm exec vitest run` for the reminders page and parser warning suites after the save-block change | Passed: 2 files, 8 tests. The first new page assertion ran while the card was collapsed; opening the card in the test fixed it. |
| `pnpm exec vitest run app/javascript/dashboard/components/widgets/AutomationTouchInput.spec.js -t 'finds appointment fields' --silent` | Passed: 1 test (20 skipped). It verifies nested mapped template parameters reach the shared field-statistics check. |
| `pnpm exec vitest run app/javascript/dashboard/i18n/specs/translationKeys.spec.js` | **Failed:** 3 of 5 tests report 235 missing Russian, 241 missing English, and 108 missing Kazakh literal keys in unrelated existing dashboard areas such as Help Center and reports. All new scheduling keys are present in all three locales. The guard is not green on this branch; no test was weakened and no broad unrelated locale edit was made. |
| Parse of the three changed scheduling JSON and three new backend YAML locale files | Passed. |
| `git diff <base> HEAD --check` | Passed. |

The focused Ruby/RSpec examples requiring Postgres or Redis **could not run on this machine**. They are written for the orchestrator's database-equipped host and are not claimed as passing. The pre-commit hook attempted to autoformat unrelated existing appointment-model lines during the first commit attempt; those edits were reverted. Subsequent commits used a per-command disabled hook after the manual checks above.

## Open questions and release limitations

- The owner must decide whether and when to apply the previewed release tasks to existing production rules and reminders, including the known blank-time rules. No production operation was performed here.
- The translation-key guard has a large unrelated existing deficit. A separate localization decision is needed before treating that guard as a release gate for this branch.
- The confirmation-reset branch is not in this base. Its integrated behavior, plus all database-backed specs, still require verification on the orchestrator host.
