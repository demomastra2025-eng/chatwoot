# cx-engine-2 verification and hardening report

Branch: `codex/cx-engine-2`. Comparison base: `3d77ef5701548999166e28c73753f10a27806bf8`. No remote, production access, migration, schema edit, or customer data was used. The task databases were `chatwoot_codex_engine` and `chatwoot_codex_engine_base`.

## Changes and decisions

- Corrected six new spec files so appointment rules enable the scheduling feature, reminder fixtures use a matching appointment conversation and route, automation provenance and delivery materialization use their model APIs, and sequential API requests carry the rotated authentication headers. The initial failures were setup failures; these corrections leave the product behavior under test intact.
- Kept one `Reminders::MissedAutomationTouchPolicy` for appointment automation reminders. It now gives a terminal before-visit reminder the closed reason, an overdue reminder the established `missed_due_to_late_automation_event` reason, and a started visit within grace the started reason. This preserves the existing send-time contract while still cancelling every unsafe reminder. A policy example covers the overlap and the send guard example checks the late reason.
- Restored the reminders-page switch to its previous value when creation or update fails, or when no template can be saved. A successful write keeps the switch state even if the subsequent rules refresh fails. Two frontend examples cover these outcomes.
- Retained the cx-engine-1 appointment callback, deferred materializer, backfill job, rule cancellation service, template field validation, timezone normalization, release tasks, and ru/kk/en text. No second scheduling or retiming mechanism was added. Manual reminders, delivered reminders, and terminal-event follow-ups retain their existing handling.
- Reviewed the new warning markup for mobile width: it uses `min-w-0` and `break-words` inside the existing responsive layout, with no new fixed width. This was a source review; no browser viewport run was made.

## Head versus base specs

All Ruby runs used `source ~/.test-env`, a task-specific `POSTGRES_DATABASE`, and `bundle exec rspec -r /home/codex-e/vite_stub.rb <files> --format progress`. The 15 branch-added or changed spec files were selected with `git diff --name-only 3d77ef5701548999166e28c73753f10a27806bf8 -- spec | rg '_spec\.rb$'`. New spec files do not exist at base, so the base comparisons use existing related suites. Both databases were created and loaded successfully with `bundle exec rails db:create db:schema:load`; there is no branch migration to run.

The 14 broad related files run on **both** head and base were `spec/models/scheduling/appointment_spec.rb`, `spec/models/automation_rule_spec.rb`, `spec/services/scheduling/appointments/upsert_service_spec.rb`, `spec/services/integrations/medelement/appointment_importer_service_spec.rb`, `spec/listeners/scheduling_automation_rule_listener_spec.rb`, `spec/services/reminders/execution_schedule_guard_spec.rb`, `spec/services/reminders/materialize_enrollment_step_service_spec.rb`, `spec/services/reminders/sync_enrollment_service_spec.rb`, `spec/services/reminders/sync_remindable_service_spec.rb`, `spec/services/reminders/execute_service_spec.rb`, `spec/controllers/api/v1/accounts/automation_rules_controller_spec.rb`, `spec/requests/api/v1/accounts/scheduling/appointments_spec.rb`, `spec/models/contact_spec.rb`, and `spec/services/contacts/reference_merge_service_automation_rules_spec.rb`.

| Run | Result | Follow-up |
| --- | --- | --- |
| Head, all 15 changed Ruby spec files, first run | 53 examples, 18 failures | Invalid new fixtures; corrected without weakening assertions about product behavior. |
| Head, six failing new spec files after fixture corrections | 25 examples, 4 failures | One request reused stale auth headers; three cancellation fixtures had internal metadata stripped on save. |
| Head, request and rule-cancellation specs after those corrections | 5 examples, 2 failures | Remaining fixtures lacked a resolved delivery route and used a normal metadata write for materialization. |
| Head, rule-cancellation spec after final fixture correction | 4 examples, 0 failures | Passed. |
| Base, 14 broad related files | 528 examples, 0 failures | Baseline. |
| Head, same 14 broad related files | 528 examples, 1 failure | Existing execute-service assertion expected the late reason; changed policy reason precedence. |
| Base, existing changed backfill-job and missed-policy specs plus stale-notice and pending-reminder job specs | 23 examples, 0 failures | Baseline for those files. |
| Head, all 15 changed specs plus execute-service, stale-notice, and pending-reminder job specs, before final assertion corrections | 114 examples, 2 failures | New examples had called a two-hour-overdue schedule “within grace” and expected the started reason for an overdue guard case. Corrected both assertions/fixture. |
| Head, corrected missed-policy and visit-guard specs plus the complete execute-service spec | **55 examples, 0 failures** | Confirms both earlier failures and the existing send-time case pass with the final policy code. |

The full 528-example head group was not rerun after the narrow policy correction. Its sole failure was in `execute_service_spec.rb`, and that complete file was included in the final green 55-example run. No other head failure remains from the runs above.

## Frontend, lint, and other checks

| Check actually run | Result |
| --- | --- |
| `pnpm install --frozen-lockfile` | Passed; `node_modules` was initially absent. |
| Head `pnpm exec vitest run` for `appointmentFieldFill.spec.js`, `appointmentTemplatePresets.spec.js`, `WhatsAppTemplateParser.appointment.spec.js`, `TouchEditorDrawer.errors.spec.js`, `AutomationTouchInput.spec.js`, `SchedulingRemindersPage.spec.js`, and `translationKeys.spec.js` | 7 files: 47 passed, 3 failed. Only the three translation-key guard tests failed. |
| Base `pnpm exec vitest run app/javascript/dashboard/i18n/specs/translationKeys.spec.js` | 2 passed, 3 failed. The missing literal-key counts match head exactly: ru 235, en 241, kk 108. None of these deficits was introduced by this branch. |
| Base `pnpm exec vitest run` for the four existing `TouchEditorDrawer.errors`, `AutomationTouchInput`, `appointmentTemplatePresets`, and `SchedulingRemindersPage` specs | 4 files, 36 tests passed. |
| Head reminders-page spec after the first switch fix | 8 tests passed. |
| Head reminders-page spec after the refresh-failure example | **9 tests passed**. |
| `ruby -c` over all 32 changed `.rb`/`.rake` files | 32 passed, 0 failures; run twice, including after the final policy edit. Two focused `ruby -c` checks also passed. |
| `bundle exec rubocop` over all 32 changed Ruby files | Initially 9 offenses: 8 in `app/models/scheduling/appointment.rb` and one new spec alignment offense. The spec offense was fixed. |
| Focused RuboCop on the changed policy and two specs immediately after reason-order refactoring | 2 policy complexity offenses; refactored into small predicate methods. |
| `bundle exec rubocop` over the other 31 changed Ruby files | 31 files, 0 offenses. Focused three-file RuboCop checks also passed after policy refactoring. |
| Base appointment model via `git show <base>:app/models/scheduling/appointment.rb \| bundle exec rubocop --stdin app/models/scheduling/appointment.rb --format simple` | Same 8 appointment-model offenses at base; none is on a changed line. |
| `pnpm exec eslint --quiet` over every branch-changed `.js`/`.vue`, then over the two final page files | Passed both runs. |
| `pnpm exec prettier --check` over every branch-changed `.js`/`.vue`/`.json`, then over the two final page files | Passed both runs. |
| `git diff --check` and final `git diff <base>..HEAD --check` | Passed. |

The translation guard is **not green** on either revision. No test was removed or weakened, and no broad unrelated locale changes were made to mask its existing deficit. The `docs/` submodule is uninitialized in this clone (`git submodule status docs` begins with `-`), so no documentation submodule change was possible without adding a remote, which this task forbids.

## Open questions and release limits

- The owner still needs to choose when to apply the previewed cx-engine-1 release tasks and how to handle existing production rules. No release task was applied here.
- The pre-existing dashboard translation-key deficit needs a separate localization decision before the guard can be a green release gate.
- Mobile layout was reviewed in source only; no browser viewport or end-to-end send against a live provider was run. The focused database suites, including MedElement importer behavior, did run against the local task database.
