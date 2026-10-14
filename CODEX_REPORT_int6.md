# int6 integration report

## What changed

- Applied all 15 package commits in the required order: r3notes, lang, outc, ws. The history is linear on `a25d8d777`; no remote was added or used.
- Added one integration commit to restore clinic-configured handoff notices for authorized, council, and failed-turn handoffs. A disabled or blank fixed notice remains silent by default. A fixed or AI-written notice is sent once while the staff note remains once. The model's legacy `handoff_message` is still ignored.
- Reconciled the runner specs with the new `outcome_run_facts` response field while retaining exact checks of the preexisting response fields. Updated handoff specs only where the packages meet.

## What was kept and why

- Round-3 rule 11, enum modes, shared FAQ and catalog read tools, and scheduling instructions remain in the integrated prompts and tool graph.
- Round-3 date rule keeps day, year, time, names, numbers, and prices, while spelling month and weekday in the patient's language. The new detected-language hint is supplied to both part owners and the council editor.
- The workspace safety controls and custom rules remain available alongside the new workspace AI routing switch and reply mode. Existing `en` and `kk` keys were kept for the translation-key guard; runtime UI remains Russian.
- The package migrations and schema changes were carried over as supplied by `ws`; no additional migration or data-deletion operation was authored or run here.

## Content conflicts resolved

1. `enterprise/lib/captain/runtime/council_editor.rb`: kept the round-3 patient-language date rule; added the run-language hint. The matching spec keeps the date assertion and checks the hint.
2. `config/llm.yml`: retained the language-only OpenAI Decisions slot and added Mercury Decide as the outcome default.
3. `lib/llm/open_router_decision_client.rb`: allowed both Decisions models in the shared client.
4. `spec/lib/llm/installation_model_config_spec.rb`: retained language-slot isolation and added Mercury outcome-slot cases.
5. `enterprise/app/services/captain/assistant/agent_runner_service.rb`: retained the detailed safety reason for staff notes and added the bounded safety kind for outcome facts. Model-supplied safety markers are discarded. The intersecting runner spec checks both fields.
6. `app/javascript/dashboard/i18n/locale/{en,kk,ru}/integrations.json`: retained round-3 safety and custom-rule labels and added the workspace routing keys. English and Kazakh were touched only to maintain key parity.
7. `app/javascript/dashboard/routes/dashboard/captain/aiSettings/Index.spec.js`: kept safety-control coverage and added workspace routing coverage.
8. `enterprise/lib/captain/account_settings.rb`: kept the round-3 safety defaults and added workspace routing defaults.

## Decisions taken

- A handoff tool call itself writes no public text. The existing `Captain::CustomerNoticeService` setting controls the public notice for every applied handoff; this preserves the clinic's fixed, generated, and silent choices without restoring duplicate legacy messages.
- The language detector and outcome classifier use separate configured decision slots. The outcome default is Mercury Decide; language detection remains OpenAI GPT-6 Luna Decisions.
- Existing package specs were changed only at the integration seams. No finding was suppressed, and no test for retained functionality was removed.

## Checks run

| Check | Result |
| --- | --- |
| `pnpm install --frozen-lockfile` | Passed; local dependencies installed. |
| `pnpm exec vitest run` on 11 touched frontend spec files, including `translationKeys.spec.js` | Passed: 11 files, 87 tests. |
| `pnpm exec vitest run` on `captainAiSettings.spec.js` and `SchedulingResourcesPage.spec.js` | Passed: 2 files, 15 tests. |
| `pnpm exec eslint` on all changed existing JS and Vue files | Passed with 0 errors and 628 warnings. |
| `bundle exec rubocop` on all 125 changed existing Ruby files | Completed with 6,274 offenses across the touched file set, many on existing code and generated schema; this is not a green full-style result. |
| `bundle exec rubocop --only Lint` on the same 125 Ruby files | Passed: 0 offenses. |
| `bundle exec rubocop --format json` on five integration Ruby files | Completed with 61 style and spec offenses before the final line-wrap edits; no lint offenses. |
| `ruby -c` on all 125 changed existing Ruby files | Passed: 0 syntax failures. |
| `ruby -c` on the four Ruby files edited in the integration fix | Passed: 4 syntax checks. |
| JSON parse of the three conflicted locale files | Passed. |
| `git diff --check`, conflict-marker search, and commit-trailer audit | Passed; 16 commits before this report ended with the required trailer. |
| `bundle exec rspec` | Not run: this machine has no Postgres or Redis. No backend spec is claimed as passed. |

The Git commit hook also reran RuboCop on the integration files and printed existing style offenses; it completed and created the commit.

## Open risks and questions

- The orchestrator must run the database-backed RSpec files listed below and apply the package migrations on its own infrastructure. Notice persistence, routing, and outcome transition behavior cannot be validated against a database here.
- The full RuboCop gate is red on the touched file set. The release gate should compare these offenses with its baseline and decide whether style cleanup is separately required.
- The configured handoff notice is generated before the persistence lock and sent only when the fenced handoff applies. The database-backed fence and retry specs need orchestrator verification.

## RSpec files for the orchestrator

The four packages touched the files below. Conflict resolutions directly touched `council_editor_spec.rb`, `installation_model_config_spec.rb`, and `agent_runner_service_spec.rb`; the integration fix also touched `response_builder_job_spec.rb` and `assistant_spec.rb`.

- `spec/controllers/api/v1/accounts/inbox_members_controller_spec.rb` (ws)
- `spec/controllers/api/v1/accounts_controller_spec.rb` (ws)
- `spec/controllers/super_admin/app_config_controller_spec.rb` (lang)
- `spec/enterprise/controllers/api/v1/accounts/captain/channel_matrix_controller_spec.rb` (ws)
- `spec/enterprise/jobs/captain/conversation/response_builder_job_spec.rb` (r3notes)
- `spec/enterprise/jobs/captain/inbox_pending_conversations_resolution_job_spec.rb` (r3notes)
- `spec/enterprise/lib/captain/assistant_prompt_spec.rb` (lang)
- `spec/enterprise/lib/captain/outcome_reason_config_spec.rb` (outc)
- `spec/enterprise/lib/captain/patient_language_spec.rb` (lang)
- `spec/enterprise/lib/captain/runtime/chat_factory_spec.rb` (lang)
- `spec/enterprise/lib/captain/runtime/council_editor_spec.rb` (lang)
- `spec/enterprise/lib/captain/tool_access_spec.rb` (r3notes)
- `spec/enterprise/lib/captain/tool_registry_spec.rb` (r3notes)
- `spec/enterprise/lib/captain/tools/handoff_tool_spec.rb` (r3notes)
- `spec/enterprise/lib/captain/tools/operations/conversation_operations_spec.rb` (r3notes)
- `spec/enterprise/migrations/unify_workspace_staff_and_assignment_spec.rb` (ws)
- `spec/enterprise/models/captain/assistant_spec.rb` (r3notes, lang)
- `spec/enterprise/models/captain_inbox_spec.rb` (ws)
- `spec/enterprise/services/captain/agent_graph_spec.rb` (ws)
- `spec/enterprise/services/captain/assistant/agent_runner_service_spec.rb` (r3notes, lang)
- `spec/enterprise/services/captain/customer_notice_service_spec.rb` (lang)
- `spec/enterprise/services/captain/outcome_classification_service_spec.rb` (outc)
- `spec/enterprise/services/captain/outcome_decision_engine_spec.rb` (outc)
- `spec/enterprise/services/captain/outcome_facts_spec.rb` (outc)
- `spec/enterprise/services/captain/patient_language_detector_spec.rb` (lang)
- `spec/enterprise/services/captain/playground/session_spec.rb` (ws)
- `spec/enterprise/services/captain/tools/copilot/get_inbox_settings_service_spec.rb` (ws)
- `spec/enterprise/services/captain/tools/copilot/list_inboxes_service_spec.rb` (ws)
- `spec/enterprise/services/captain/tools/copilot/set_inbox_assignment_policy_service_spec.rb` (ws)
- `spec/enterprise/services/captain/tools/copilot/update_captain_inbox_auto_reply_mode_service_spec.rb` (ws)
- `spec/enterprise/services/captain/tools/copilot/update_inbox_settings_service_spec.rb` (ws)
- `spec/enterprise/services/captain/tools/copilot/update_inbox_working_hours_service_spec.rb` (ws)
- `spec/enterprise/services/enterprise/message_templates/hook_execution_service_spec.rb` (r3notes)
- `spec/helpers/reporting_event_helper_spec.rb` (ws)
- `spec/jobs/auto_assignment/periodic_assignment_job_spec.rb` (ws)
- `spec/lib/llm/config_spec.rb` (lang, outc)
- `spec/lib/llm/haiku_model_configuration_spec.rb` (outc)
- `spec/lib/llm/installation_model_config_spec.rb` (lang, outc)
- `spec/lib/llm/models_spec.rb` (lang, outc)
- `spec/lib/llm/open_router_capability_resolver_spec.rb` (lang, outc)
- `spec/lib/llm/open_router_decision_client_spec.rb` (outc)
- `spec/lib/llm/open_router_decision_runtime_spec.rb` (lang)
- `spec/migrations/add_workspace_working_hours_inheritance_to_inboxes_spec.rb` (ws)
- `spec/models/account_user_spec.rb` (ws)
- `spec/models/concerns/account_workspace_working_hours_spec.rb` (ws)
- `spec/models/inbox_spec.rb` (ws)
- `spec/models/scheduling/resource_workspace_hours_spec.rb` (ws)
- `spec/services/reminders/delivery_window_policy_spec.rb` (ws)
- `spec/services/scheduling/resource_schedule_service_spec.rb` (ws)
