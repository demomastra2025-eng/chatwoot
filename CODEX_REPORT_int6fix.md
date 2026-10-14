# int6fix integration report

The supplied orchestrator log recorded 1,205 examples and 158 failures on the integrated candidate before this task.

## What changed

- The Captain inbox test factory now selects a workspace main agent when it creates an enabled text AI link for a workspace without one. This exercises the routing gate used by real text channels and restores the job and hook test paths. Voice and disabled text links keep their existing setup.
- The patient-language detector locks a fresh persisted conversation and reads the previous hint from the database. This avoids a failed `with_lock` when message callbacks have left `display_id` dirty on the caller's instance.
- Text reply-time checks explicitly use workspace availability. A private Captain staff note cannot trigger the email collection template, and an inactive entry agent opens a pending conversation for staff without writing an agent note.
- Integration specs now use workspace reply modes and schedules, recognize automatic AI links on new channels, select private staff notes when a configured public notice follows them, and model classifier staff notes as outgoing private messages. The membership, routing, and model-config expectations were aligned with the package decisions.
- Wider Captain specs now model all active external agents as text routes, the workspace assignment policy and membership, private notes as ordinary agent tools, and run-context outcome facts.
- Playground's synthetic namespace preserves the persisted Captain assistant ID carried in native reminder payloads. The legacy Copilot inbox-removal tool reports only memberships actually removed and describes its workspace behavior accurately; `script/onelink/WORKSPACE_SETTINGS.md` records the response behavior.

## Kept and why

- The workspace main-agent requirement, per-channel AI switch, workspace emergency switch and hours, all-external-agent text routing, and shared staff membership remain intact.
- The r3notes staff-note behavior and the integrated candidate's clinic-configured handoff notices remain intact. No model-supplied legacy handoff message was restored.
- The language decision slot, outcome run facts and classifier, response fences, and council behavior remain intact.
- No migration, data deletion, secret, finding suppression, or `config/brakeman.ignore` change was made. No remote was added or used.

## Decisions

- Enabled text assignments created by the shared factory receive a main agent only when their workspace lacks one. Specs that must model an unstarred or inactive agent explicitly clear the main-agent setting before deactivation or destruction.
- Workspace hours, rather than historical inbox hours, drive the reply-mode test setup. Historical inbox fields remain stored for compatibility.
- A disabled entry is distinct from an active Captain that is outside its schedule: both open the conversation for people, but only the active agent writes the schedule staff note.
- A legacy inbox removal request keeps all workspace staff attached. The tool returns an empty `removed_user_ids` array when the workspace rule leaves membership intact.

## Verification

| Check | Result |
| --- | --- |
| `source /home/codex-e/rspec-int6fix.env && bundle exec rake db:create db:schema:load` | Passed on the dedicated test database. |
| Initial focused `rspec` on ResponseBuilder and hook files | 199 examples, 14 failures after the first factory change; failures were traced and fixed. |
| Focused patient-language detector runs | 4/2, debug 1/1, 4/3, then 4/0. The debug change was removed. |
| Focused six-file API, runner, outcome, Playground, Copilot, and LLM config run | 233 examples, 0 failures. |
| Captain inbox model | 11/2, then 11/0 after updating the inactive-main setup. |
| Four previously failing ResponseBuilder examples | 4 examples, 0 failures. |
| Six neighboring routing files | 34/1, focused inactive-entry example 1/0, then 34/0. |
| Hook file | 52/7, 52/2, then 52/0. |
| Full ResponseBuilder file | 147 examples, 0 failures. |
| Original 49-file integration set | 1,206 examples, 0 failures across 49 selected files. |
| First complete `spec/enterprise/lib/captain` and `spec/enterprise/services/captain` sweep | 4,307 examples, 33 failures, 4 pending. Twenty-two failures exposed outdated specs or the Playground namespace bug. Eleven concurrency examples could not pass their cleanup guard on `chatwoot_test_int6fix`; the guard refused to truncate this database. |
| Nine additional affected Captain files | 101 examples, 2 failures; both expectations were corrected. |
| Full legacy conversion and Copilot directory files after correction | 21 examples, 0 failures. |
| `spec/enterprise/lib/captain` safe sweep | 2,594 examples, 0 failures, 4 pending. |
| `spec/enterprise/services/captain` safe sweep, excluding the two concurrency files with destructive cleanup | 1,702 examples, 0 failures, 0 pending. |
| Combined safe Captain directory sweep | 4,296 examples, 0 failures, 4 pending. |
| Strengthened full legacy conversion file after the safe sweep | 9 examples, 0 failures. |
| `ruby -c` on every changed Ruby file | Passed, 27 syntax checks. |
| RuboCop on every changed Ruby file with repository config | 0 offenses on changed lines across 27 files. Lint-only runs passed. |
| `pnpm install --frozen-lockfile` | Passed. |
| `pnpm exec vitest run app/javascript/dashboard/i18n/specs/translationKeys.spec.js` | 5 tests, 0 failures. |
| `git diff --check`, linear-history and trailer audit | Passed before the report commit: clean diff, nine linear implementation commits, all with the required trailer. |

The full sweep includes `control_service_concurrency_spec.rb` and `control_service_incoming_concurrency_spec.rb`. Their `CommittedRowsCleanup` guard accepts only `chatwoot_test` or numbered variants, and refuses the dedicated `chatwoot_test_int6fix` database. These specs use table truncation; task rules prohibit data deletion. The safe sweep excludes exactly these two files, and no cleanup guard or concurrency assertion was weakened.

RSpec runs used the dedicated `chatwoot_test_int6fix` database and Redis DB 1 from the supplied environment file. No production system was accessed. Intermediate failures are listed because they were real check results, not green claims.

The changed-line audit compares RuboCop JSON positions with the complete diff from the integrated candidate base. Earlier smaller RuboCop runs also found no changed-line offenses.

## Final per-file RSpec results

The 49 selected files passed 1,206 examples. RSpec attributes five shared examples to `spec/models/concerns/avatarable_shared.rb`, so the table has 50 source paths.

| Spec file | Examples | Failures |
| --- | ---: | ---: |
| `spec/controllers/api/v1/accounts/inbox_members_controller_spec.rb` | 8 | 0 |
| `spec/controllers/api/v1/accounts_controller_spec.rb` | 30 | 0 |
| `spec/controllers/super_admin/app_config_controller_spec.rb` | 35 | 0 |
| `spec/enterprise/controllers/api/v1/accounts/captain/channel_matrix_controller_spec.rb` | 6 | 0 |
| `spec/enterprise/jobs/captain/conversation/response_builder_job_spec.rb` | 147 | 0 |
| `spec/enterprise/jobs/captain/inbox_pending_conversations_resolution_job_spec.rb` | 41 | 0 |
| `spec/enterprise/lib/captain/assistant_prompt_spec.rb` | 23 | 0 |
| `spec/enterprise/lib/captain/outcome_reason_config_spec.rb` | 8 | 0 |
| `spec/enterprise/lib/captain/patient_language_spec.rb` | 4 | 0 |
| `spec/enterprise/lib/captain/runtime/chat_factory_spec.rb` | 44 | 0 |
| `spec/enterprise/lib/captain/runtime/council_editor_spec.rb` | 33 | 0 |
| `spec/enterprise/lib/captain/tool_access_spec.rb` | 15 | 0 |
| `spec/enterprise/lib/captain/tool_registry_spec.rb` | 11 | 0 |
| `spec/enterprise/lib/captain/tools/handoff_tool_spec.rb` | 24 | 0 |
| `spec/enterprise/lib/captain/tools/operations/conversation_operations_spec.rb` | 15 | 0 |
| `spec/enterprise/migrations/unify_workspace_staff_and_assignment_spec.rb` | 4 | 0 |
| `spec/enterprise/models/captain/assistant_spec.rb` | 111 | 0 |
| `spec/enterprise/models/captain_inbox_spec.rb` | 11 | 0 |
| `spec/enterprise/services/captain/agent_graph_spec.rb` | 9 | 0 |
| `spec/enterprise/services/captain/assistant/agent_runner_service_spec.rb` | 141 | 0 |
| `spec/enterprise/services/captain/customer_notice_service_spec.rb` | 45 | 0 |
| `spec/enterprise/services/captain/outcome_classification_service_spec.rb` | 18 | 0 |
| `spec/enterprise/services/captain/outcome_decision_engine_spec.rb` | 3 | 0 |
| `spec/enterprise/services/captain/outcome_facts_spec.rb` | 4 | 0 |
| `spec/enterprise/services/captain/patient_language_detector_spec.rb` | 4 | 0 |
| `spec/enterprise/services/captain/playground/session_spec.rb` | 21 | 0 |
| `spec/enterprise/services/captain/tools/copilot/get_inbox_settings_service_spec.rb` | 2 | 0 |
| `spec/enterprise/services/captain/tools/copilot/list_inboxes_service_spec.rb` | 2 | 0 |
| `spec/enterprise/services/captain/tools/copilot/set_inbox_assignment_policy_service_spec.rb` | 6 | 0 |
| `spec/enterprise/services/captain/tools/copilot/update_captain_inbox_auto_reply_mode_service_spec.rb` | 7 | 0 |
| `spec/enterprise/services/captain/tools/copilot/update_inbox_settings_service_spec.rb` | 4 | 0 |
| `spec/enterprise/services/captain/tools/copilot/update_inbox_working_hours_service_spec.rb` | 5 | 0 |
| `spec/enterprise/services/enterprise/message_templates/hook_execution_service_spec.rb` | 52 | 0 |
| `spec/helpers/reporting_event_helper_spec.rb` | 7 | 0 |
| `spec/jobs/auto_assignment/periodic_assignment_job_spec.rb` | 9 | 0 |
| `spec/lib/llm/config_spec.rb` | 43 | 0 |
| `spec/lib/llm/haiku_model_configuration_spec.rb` | 13 | 0 |
| `spec/lib/llm/installation_model_config_spec.rb` | 24 | 0 |
| `spec/lib/llm/models_spec.rb` | 56 | 0 |
| `spec/lib/llm/open_router_capability_resolver_spec.rb` | 23 | 0 |
| `spec/lib/llm/open_router_decision_client_spec.rb` | 17 | 0 |
| `spec/lib/llm/open_router_decision_runtime_spec.rb` | 9 | 0 |
| `spec/migrations/add_workspace_working_hours_inheritance_to_inboxes_spec.rb` | 1 | 0 |
| `spec/models/account_user_spec.rb` | 12 | 0 |
| `spec/models/concerns/account_workspace_working_hours_spec.rb` | 5 | 0 |
| `spec/models/concerns/avatarable_shared.rb` | 5 | 0 |
| `spec/models/inbox_spec.rb` | 71 | 0 |
| `spec/models/scheduling/resource_workspace_hours_spec.rb` | 2 | 0 |
| `spec/services/reminders/delivery_window_policy_spec.rb` | 9 | 0 |
| `spec/services/scheduling/resource_schedule_service_spec.rb` | 7 | 0 |

The wider Captain sweep also checked these files that failed in its first run:

| Spec file | Examples | Failures |
| --- | ---: | ---: |
| `spec/enterprise/lib/captain/runtime/council/part_run_spec.rb` | 15 | 0 |
| `spec/enterprise/lib/captain/runtime/handoff_monitoring_spec.rb` | 25 | 0 |
| `spec/enterprise/lib/captain/tools/add_contact_note_tool_spec.rb` | 14 | 0 |
| `spec/enterprise/lib/captain/tools/resolve_conversation_tool_spec.rb` | 10 | 0 |
| `spec/enterprise/services/captain/agent_run_context_spec.rb` | 20 | 0 |
| `spec/enterprise/services/captain/assistant/prompt_preview_service_spec.rb` | 9 | 0 |
| `spec/enterprise/services/captain/conversation/follow_up_control_fence_spec.rb` | 1 | 0 |
| `spec/enterprise/services/captain/conversation/run_fence_service_spec.rb` | 13 | 0 |
| `spec/enterprise/services/captain/copilot/chat_service_spec.rb` | 40 | 0 |
| `spec/enterprise/services/captain/legacy_scenario_conversion_service_spec.rb` | 9 | 0 |
| `spec/enterprise/services/captain/playground/workspace_adapters_spec.rb` | 9 | 0 |
| `spec/enterprise/services/captain/tools/copilot/account_directory_tools_spec.rb` | 12 | 0 |
| `spec/enterprise/services/captain/tools/copilot/add_inbox_members_service_spec.rb` | 4 | 0 |
| `spec/enterprise/services/captain/tools/copilot/remove_inbox_members_service_spec.rb` | 4 | 0 |

The safe sweep excluded `control_service_concurrency_spec.rb` (10 examples) and `control_service_incoming_concurrency_spec.rb` (1 example). All 11 failed their database-name cleanup guard in the first full sweep and have no final passing result.

## Open questions and limits

- The 11 concurrency examples require committed-row cleanup with table truncation. Their guard rejects the required dedicated database name, and this task prohibits data deletion. They remain unverified here; the release pipeline needs an approved non-destructive test strategy or an environment whose cleanup is permitted by the owner. The guard and assertions were not changed.
- The `docs/` submodule is uninitialized in this clone, so its public and internal pages could not be updated here. Runtime behavior follows the existing workspace and Captain package decisions.
- The carried workspace question about automatically starring a later-activated first agent remains undecided. This task leaves that behavior unchanged.
