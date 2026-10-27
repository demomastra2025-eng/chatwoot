# cx-integ-1 integration report

Branch: `codex/cx-integ-1` (the checked-out task branch). Base: `base-cx-integ-1` at `05d3eb766`.

## Changes and conflict resolution

- Merged `integ-wwd`, `integ-mes`, then `integ-qf2` with `--no-ff`, preserving their histories. The merge commit subjects follow the requested `Merge <name> into rel-20261027c` form.
- `integ-wwd`: kept the newer schema version and the calendar phone editor from the urgent scheduling fixes. Removed its obsolete inbox-cache refresh, then refreshed the active person dialog through the current Vuex action after a phone save. The first message still creates the dialog; opening it does not create an empty conversation.
- `integ-mes`: kept both scheduling routes and the MedElement patient search in the calendar picker. Combined the existing Kazakh scheduling overrides with the new patient-search catalog. Updated the fallback spec to cover the combined locale shape.
- `integ-qf2`: kept `Scheduling::ServiceIndex` as the service retrieval path and did not restore the deleted `Scheduling::ServiceSearch` or its spec. Its Kazakh letter folding is already in the shared `Scheduling::SearchText`, with tests. The old SQL search's dental/lumbar token aliases were not copied into the vector index. Kept the agreed-visit silence check, reply wording, and related quality fixes. Removed the reply suggestion's channel anchor because the main-agent removal leaves no default agent. The router selects the most probable candidate, with its current-agent tie preference, and the updated specs cover that behavior. Kept the existing no-agent configuration messages alongside the new claim text in the three Captain locale files.
- Corrected the new agreed-visit routing spec to use the channel router and an established agent. Its original direct-assistant setup bypassed routing, so it could not exercise the silence check it asserted.
- Enabled scheduling on both MedElement hook accounts in the new patient-directory spec. Without it, all eight examples failed during fixture creation before they reached the search behavior.
- Made the new refused-send spec compare record counts before and after the rejected message. Its previous expectation of zero rows assumed an empty shared test database and failed even though the transaction left its own records unchanged.
- Made the new contact call and dialog request specs compare each request's record changes against a starting snapshot. The old absolute-count assertions failed when unrelated records existed in the shared test database.

## Migration order

| Version | Migration |
| --- | --- |
| `20261027120000` | Service embeddings and embedding model names (base) |
| `20261027130000` | Enable communication threads default feature flag (`integ-wwd`) |
| `20261027150000` | Remove main agent (base) |
| `20261027160000` | Contact name-parts trigram index (`integ-mes`) |

The versions are unique and increasing. `db/schema.rb` is at `2026_10_27_160000`; `db:migrate:status` showed all four as `up` after schema load. No migration was authored in this task.

## Verification

The supplied `~/.test-env` connected to a local Postgres test service at `127.0.0.1:55996`. Only disposable test databases were used. The initial broad RSpec invocation stopped at two load errors before examples; the same two specs fail to load on the base (`AssignUserToTeamService` and `ListTeamsService` constants), so the comparable run excludes them. No production system was accessed.

| Check | Head result | Base result |
| --- | --- | --- |
| `bundle exec rails db:create db:schema:load` with `POSTGRES_DATABASE=chatwoot_codex_integ` | Passed | Not run |
| `bundle exec rails db:migrate:status` | Passed; all four migrations `up` | Not run |
| `pnpm install --frozen-lockfile` | Passed | Shared installed dependencies |
| `bundle exec rspec -r /home/codex-e/vite_stub.rb` for the requested Ruby matrix, before exclusions | 0 examples; 2 load errors | `--dry-run` reproduced both load errors |
| Requested Ruby matrix excluding the two base load-error files | First invocation completed 3,623 examples before it stalled in `agent_runner_service_spec.rb` and was interrupted; that file passed all 142 examples in isolation; the remaining 414 files ran 4,837 examples with 144 failures in 63m 18s, including later-fixed test-fixture/count assertions | Full base execution not run; matching failed files are compared below |
| Ruby matrix `--dry-run` with those exclusions | 8,540 examples, 4 pending | 8,335 examples, 4 pending |
| Focused router, silence, and search-text RSpec files | 124 examples, 0 failures after the integration test correction | 98 examples, 4 pre-existing stale router-spec failures on a separate base-schema database (the SilenceCheck spec does not exist on base) |
| Full routing spec after the agreed-visit setup correction | 21 examples, 1 unchanged base failure | 19 examples; the same no-agent suppression assertion fails |
| New MedElement patient-directory spec after fixture correction | 8 examples, 0 failures | Spec does not exist on base |
| `spec/requests/api/v1/accounts/scheduling/medelement_patients_spec.rb` | 5 examples, 0 failures on the head-schema focus database | Spec does not exist on base |
| New message-create refused-send example after count correction | 1 example, 0 failures; the other 16 examples passed before the correction | Spec does not exist on base |
| Contact call and dialog request specs after count correction | 30 examples, 0 failures | Specs do not exist on base |
| `spec/models/contact_spec.rb` | 56 examples, 0 failures | 56 examples, 0 failures |
| Initial broad Vitest command with `--maxWorkers=4` | Did not run tests: worker setting conflicted with repo minimum | Not run |
| Broad Vitest scheduling, contacts, conversation, captain/agent, i18n | 181 files; 178 passed, 3 failed; 2,288 passed, 5 failed (before fixes) | 177 files; 174 passed, 3 failed; 2,216 passed, 4 failed; one file could not load |
| Final broad Vitest after fixes | 181 files: 180 passed, 1 failed; 2,290 tests passed, 3 failed, all in `translationKeys.spec.js` | Above |
| Focused calendar and scheduling-fallback Vitest | 2 files, 15 tests passed | The fallback assertion fails on base |
| `translationKeys.spec.js` | 3 failures: ru 235, en 241, kk 108 missing keys | The exact same missing-key sets and counts |
| Ruby `ruby -c` on the seven directly resolved/updated Ruby files | Passed | Not run |
| `ruby -c` on the final agreed-visit routing spec | Passed | Not run |
| `ruby -c` and commit-hook RuboCop on the patient-directory spec | Passed; 0 RuboCop offenses | Spec does not exist on base |
| `ruby -c` and commit-hook RuboCop on the message-create spec | Passed; 0 RuboCop offenses | Spec does not exist on base |
| `ruby -c` and commit-hook RuboCop on the contact call/dialog request specs | Passed; 0 RuboCop offenses in both files | Specs do not exist on base |
| Targeted `bundle exec rubocop --format simple` on seven Captain files | 4 existing metric offenses after fixes | 4 metric offenses on the same files |
| `bundle exec rubocop --format simple` on the final routing spec | 1 existing `RSpec/MultipleMemoizedHelpers` offense | 9 offenses, including the same memoized-helper offense and 8 auto-correctable alignment issues |
| Targeted `pnpm exec eslint` | 0 errors; 214 scheduling i18n warnings | Not run |
| Targeted `pnpm exec prettier --check` | Passed | Not run |
| `git diff --check` and conflict-marker search | Passed | Not run |
| First-parent commit-message trailer audit | All 11 task commits before this report end with the required `Co-Authored-By` trailer | Base commits untouched |

The completed 4,837-example head remainder's 144 failures split into 17 merge-related test setup or count assumptions corrected in focused reruns and 127 failures reproduced on base in matching files. The earlier interrupted prefix had 36 failure markers: 2 corrected router assertions and 34 base-matched failures. These are counts from separate invocations, not a claim that the full matrix passed in one run. No backend full-matrix rerun was made after the focused fixes; it previously took over an hour and includes the recorded base failures.

The initial focused Vitest run passed 14 tests in 3 files. The broad base Vitest suite's load error is in the old `ComposeConversation.spec.js` (`emitter.on is not a function`). Its other failures are the translation-key guard and the old scheduling-fallback expectation. The head's two additional broad-suite failures were the calendar phone refresh and the merged locale shape; both passed in the focused rerun. The public docs submodule is uninitialized in this clone, and no remote is configured, so docs content could not be updated here.

The first focused Ruby run had 124 examples and 2 failures: two `integ-qf2` assertions expected `no_reply_needed` with no agent leading the dialog. The base requires routing to the most probable candidate in that case, so the integrated specs now assert that route while retaining the quality fix's silence checks for a dialog with a current agent. The rerun passed all 124 examples.

The two agreed-visit confirmation examples passed after the test setup correction. The full head routing spec then ran 21 examples with one failure, the unchanged base failure for a no-agent reply suggestion that expects suppression. The same routing spec has 19 examples on base.

For a comparable Ruby prefix (the first eleven Captain spec files), head and base each ran 112 examples with the same one failure: `strict_structured_output_schema_spec.rb` still expects four part statuses although both revisions expose `no_reply_needed` as a fifth. This is pre-existing and was left as requested. The five-file head Captain routing batch passed 72 examples; its base counterpart ran 67 examples with one stale anchor expectation.

The five-file image/customer-notice batch ran 140 examples with 18 failures on both head and base; the failing example descriptions match exactly. A separate five-file base batch for routing benchmark, assistant operations registry, availability snapshot, job image description, and incoming concurrency ran 14 examples with 5 failures, matching the same five failures indexed in the broad head run. These failures were not changed.

`control_service_concurrency_spec.rb` ran 10 examples with 10 failures on both head and base, again with identical failing example descriptions.

The five-file Captain image-history/legacy-description/custom-rule/response-rewrite/language-detector batch ran 80 examples with 72 failures on base. The same five files contribute exactly 72 failures with matching spec descriptions in the broad head run; these are pre-existing.

`workspace_profile_tools_spec.rb` ran 9 examples with 8 failures on base, the same eight descriptions failing on head; the fixture assigns a `domain` attribute that `Account` does not have. This file was not changed by the merges.

`get_inbox_settings_service_spec.rb` ran 3 examples with 1 failure on base, matching the one head failure; neither the implementation nor its spec was changed by these merges.

`hook_runtime_lock_spec.rb` ran 2 examples with 2 failures on both revisions: its committed-row cleanup refuses the supplied `chatwoot_codex_integ*` database names because they do not match that helper's test-database naming guard. The merged code did not change this spec or helper.

`missing_appointment_reconciler_concurrency_spec.rb` ran 1 example with 1 failure on both revisions for the same database-name guard.

`hook_runtime_lock_adjacent_operations_spec.rb` ran 4 examples with 4 failures on both revisions for that guard as well.

`hook_runtime_lock_hook_teardown_serialization_spec.rb` ran 2 examples with 2 failures on both revisions for the same guard.

`provider_commands/create_service_concurrency_spec.rb` ran 1 example with 1 failure on both revisions for the same guard.

`appointment_importer_service_concurrency_spec.rb` ran 1 example with 1 failure on both revisions for the same guard.

`appointments_shared_phone_released_spec.rb` ran 5 examples with 4 failures on both revisions, with matching failing descriptions. This unchanged scheduling request spec was left as a base failure.

`reminders/conversation_resolver_spec.rb` ran 29 examples with 3 failures on base, matching the same three head failures about email subject metadata. The spec and implementation are unchanged by these merges.

`reminders/execute_service_follow_up_lock_order_spec.rb` ran 1 example with 1 failure on both revisions; it hits the same committed-row cleanup database-name guard.

`reminders/execute_service_transfer_concurrency_spec.rb` ran 2 examples with 2 failures on both revisions for that guard.

`reminders/patient_subject_guard_contact_inbox_race_spec.rb` ran 5 examples with 5 failures on both revisions for that guard.

`reminders/execute_service_follow_up_concurrency_spec.rb` ran 1 example with 1 failure on both revisions for that guard.

The account and contact-inbox model pair ran 80 examples with 12 failures on base, matching the 11 account and 1 contact-inbox failures in the completed head remainder. The account spec refers to attributes that neither revision has; the contact-inbox example reads the first row in a shared database rather than its created row. Both specs are unchanged by the merges.

The new `patient_directory_search_spec.rb` initially ran 8 examples with 8 fixture-setup failures because MedElement hooks require scheduling. After enabling that feature in the fixtures, all 8 examples passed on a head-schema focus database. This spec does not exist on base.

The new `message_create_service_spec.rb` initially ran 17 examples with 1 failure: an absolute zero-row assertion saw unrelated records in the shared test database. Its corrected refused-send example passed in isolation, and the other 16 examples had passed in the full-file run. The spec does not exist on base.

The new contact call and dialog request specs accounted for seven broad-run failures caused by absolute database counts. After changing them to assert record deltas, their combined focused run passed all 30 examples on the shared head-schema focus database. These specs do not exist on base.

The broad head Ruby run did not progress after 3,623 completed examples (36 failure markers, including two stale router expectations already corrected): its process waited on a thread and Postgres showed idle connections. The apparent stopping example passed in isolation on both revisions. After several minutes, the runner was interrupted; `agent_runner_service_spec.rb` (142 examples in the dry-run index) and the 414 subsequent files (4,837 examples, 144 failures) were run separately. The interrupted run produced no final RSpec summary, so its progress count is reported as completed examples, not as a completed suite. The separate runs overlap the 62 AgentRunner examples already completed; together they cover the whole 8,540-example index. The 4,837-example invocation began before the later test fixes, so its total includes failures corrected in focused reruns.

An initial base-focused attempt used the head-schema focus database and failed before examples: Rails schema maintenance timed out, leaving that disposable database invalid. The base comparison then used its own fresh base-schema database. A JSON dry-run against the invalid focus database likewise failed before examples; the same dry-run against the main head-schema test database succeeded and indexed all 8,540 examples. No database was dropped.

## Open questions

- Should the new embedding-based service search get explicit Kazakh dental/lumbar synonym calibration if a real evaluation finds misses? The old SQL token aliases were specific to the removed search mechanism; no parallel SQL search was introduced.
