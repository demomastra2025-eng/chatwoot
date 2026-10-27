# cx-speed-r review report

Reviewed `3d77ef5701548999166e28c73753f10a27806bf8..718a4041c` and the nearby scheduling, patient-scope, FAQ, runtime, and UI code. This review adds two code commits on `codex/cx-speed-r`: `c6f17bb93` and `a32018d3a`. No remote, production system, migration, or application database was used.

## Findings fixed

1. `enterprise/app/services/captain/tools/account/search_booking_options_service.rb:148`: a request with a named doctor and a service absent from the catalog returned no doctor availability. The service result remains `not_in_catalog`, while the separate specialist block now includes that doctor's general slots. The regression spec covers the mixed input. The tool still delegates matching and availability to the existing three searches.
2. `enterprise/app/services/captain/reply_suggestion/faq_preload.rb:93`: one oversized top FAQ answer could bypass the 4,000-character budget. Oversized or empty answers are now skipped whole, and later relevant candidates can fill the three-match limit. `faq_lookup` remains available to read the omitted answer. The spec covers this case.
3. `enterprise/lib/captain/prompts/assistant.liquid:12`, `config/captain/agent_tool_texts.yml:113`: older day-only and source-check wording conflicted with combined-first booking guidance. The prompt now sends booking-option questions to the combined search, exact-time checks to `search_available_slots`, and price-only questions to `search_scheduling_services`. This avoids an unnecessary availability query for a pure price question. Prompt and tool-text specs cover the rule.
4. `app/javascript/dashboard/i18n/locale/kk/integrations.json:1156`: the new tool lacked a Kazakh title and description. Added them alongside the existing Russian and English entries. No new customer-facing English text was added.

## What was kept and why

- `search_booking_options` remains scoped to reply suggestions for patient agents that already have slot search. Its inputs are optional `services` (array of service mentions), `doctor` (name or specialty), `from`, and `to` (clinic-local date or datetime). At least `services` or `doctor` is required. Its default range is seven days, and the underlying slot search enforces the 31-day maximum. Its JSON answer has `results` per mention with catalog candidates, score, price, duration and doctor names; slots of the best candidate are labelled `slots_service_id` and have specialist-day rows `{resource_id, name, date, times, more}`. A named doctor produces a separate `specialists` block. The answer also carries range, sample-times note, skipped queries, and explicit missing/unchecked slot statuses. It reuses `SearchSchedulingServicesService`, `SearchSchedulingResourcesService`, and `SearchAvailableSlotsService`; no second matching or availability algorithm was added. Caps remain eight mentions, 15 service entries, slots for three mentions, four doctors per slot block, two days per doctor, and five starts per day. Six named-specialist records may be listed, but only the first four are searched for slots.
- The patient preload remains limited to the current account's contact and `Scheduling::PatientContextQuery#patients` circle. It includes the contact card fields from `get_my_contact`, up to six upcoming appointment cards plus the total, and IDs for appointments that the patient tool scope can act on directly. Other circle members are named, but their appointment IDs are not put in the prompt because their mutation tools require an access token from `search_appointments`. These tools remain for other ranges and fresh reads.
- FAQ preload still uses the existing Gemini embedding model, account and assistant visibility scope, and 0.7 similarity threshold. It embeds the latest patient text while routing and waits at most three seconds; at most three whole answers totaling 4,000 answer characters enter the prompt. A miss or timeout leaves `faq_lookup` available. The preload adds no new external destination.
- Multiple model tool calls in one step remain sequential in RubyLLM (`concurrency: false`). Each call retains its own guard, approval-card rule, instrumentation, read cache and UI stage. The OpenRouter policy only sends `parallel_tool_calls: true` for eligible read-only flows; the runtime can still process a model response containing several calls in one step. `captain.reply_suggestion.complete` retains `steps`, `tool_steps`, `parallel_steps`, `max_tools_in_step`, `tools_called`, and `total_ms`.
- Did not broaden child/relative appointment mutations by ID or add a new eligibility rule based on a price link. Those would change access or clinical meaning beyond this speed review. Did not truncate a FAQ answer mid-instruction; an oversized answer is read via `faq_lookup` if needed.

## Verification

- `bundle check`: passed.
- `pg_isready -h 127.0.0.1 -p 5432`: accepted a connection. `redis-cli ping`: could not run because `redis-cli` is not installed. No Redis service was started.
- Initial `bundle exec rspec -r /home/codex-e/vite_stub.rb` for four focused files: 0 examples, 4 load errors because the named test DB did not yet exist. `bundle exec rails db:exists` was attempted and failed because this Rails version has no such command.
- `source ~/.test-env; POSTGRES_DATABASE=chatwoot_codex_speed bundle exec rails db:create db:schema:load`: passed on a newly created, isolated test DB. The same command with `chatwoot_codex_speed_base` passed in the base worktree. No migration ran.
- First focused head RSpec run (FAQ, booking options, assistant prompt, tool texts): 98 examples, 1 failure in a newly written spec that tried to persist a 500-character FAQ question; the model validates a 255-character maximum. Removed that redundant test and cap.
- Head: `source ~/.test-env; POSTGRES_DATABASE=chatwoot_codex_speed bundle exec rspec -r /home/codex-e/vite_stub.rb <all 17 branch-touched Ruby spec files> --format progress`: **432 examples, 0 failures**.
- Base `3d77ef570`: the same command for the nine comparable pre-existing suites with `POSTGRES_DATABASE=chatwoot_codex_speed_base`: **336 examples, 0 failures**. The eight new suites do not exist on base.
- After the final prompt edits, head RSpec for `assistant_prompt_spec.rb`, `agent_tool_texts_spec.rb`, and `agent_runner_service_generate_response_booking_flow_spec.rb`: **65 examples, 0 failures**.
- `pnpm install --frozen-lockfile`: passed. `pnpm exec vitest run app/javascript/dashboard/composables/spec/suggestionStages.spec.js app/javascript/dashboard/i18n/specs/translationKeys.spec.js`: stage suite **71 passed**; translation-key guard **3 failed, 2 passed** (76 total). The base translation-key guard also has **3 failed, 2 passed**. Its failures are existing missing literal keys across ru/en/kk, unrelated to this branch's new tool label. The guard is not green on either revision.
- `pnpm exec eslint` on the changed stage files and translation guard: passed. `pnpm exec prettier --check` on changed stage files and Kazakh JSON: passed. `bundle exec rubocop` on the six edited Ruby files: passed after fixing two layout offenses found on the first run. `ruby -c` on those six files: passed. YAML and JSON parsing: passed. `git diff --check`: passed.
- No live model evaluation or DEV smoke was run. The 125-case latency comparison in the task description was supplied by the requester and was not repeated here.

## Open questions and limits

- The combined answer lists the service-search candidates and the slot result for the best candidate. If a later candidate is the correct service, the agent must use the separate slot search. The name-match rule remains the quality guard; live answer quality has not been measured in this clone.
- The `docs/` submodule content is not checked out in this clone, so no internal documentation page could be edited here. The tool and behavior contract is recorded in this report and code comments.
- The base translation-key guard needs a separate localization cleanup. This task did not suppress findings or alter its known-missing list.

### Exact command log

The following commands ran from the head worktree unless a base path is stated. The result of each is above; early failed attempts were kept in the record.

```sh
bundle check
pg_isready -h 127.0.0.1 -p 5432
redis-cli ping
source ~/.test-env; POSTGRES_DATABASE=chatwoot_codex_speed bundle exec rails db:exists
source ~/.test-env; POSTGRES_DATABASE=chatwoot_codex_speed bundle exec rspec -r /home/codex-e/vite_stub.rb spec/enterprise/services/captain/reply_suggestion/faq_preload_spec.rb spec/enterprise/services/captain/tools/account/search_booking_options_service_spec.rb spec/enterprise/lib/captain/assistant_prompt_spec.rb spec/enterprise/lib/captain/runtime/agent_tool_texts_spec.rb
source ~/.test-env; POSTGRES_DATABASE=chatwoot_codex_speed bundle exec rails db:create db:schema:load
source ~/.test-env; POSTGRES_DATABASE=chatwoot_codex_speed_base bundle exec rails db:create db:schema:load # base worktree
source ~/.test-env; POSTGRES_DATABASE=chatwoot_codex_speed bundle exec rspec -r /home/codex-e/vite_stub.rb spec/enterprise/services/captain/reply_suggestion/faq_preload_spec.rb spec/enterprise/services/captain/tools/account/search_booking_options_service_spec.rb spec/enterprise/lib/captain/assistant_prompt_spec.rb spec/enterprise/lib/captain/runtime/agent_tool_texts_spec.rb --format progress
source ~/.test-env; mapfile -t speed_specs < <(git diff --name-only 3d77ef570..HEAD -- spec | rg '_spec\.rb$'); POSTGRES_DATABASE=chatwoot_codex_speed bundle exec rspec -r /home/codex-e/vite_stub.rb "${speed_specs[@]}" --format progress
source ~/.test-env; POSTGRES_DATABASE=chatwoot_codex_speed_base bundle exec rspec -r /home/codex-e/vite_stub.rb spec/enterprise/lib/captain/appointment_context_spec.rb spec/enterprise/lib/captain/assistant_prompt_spec.rb spec/enterprise/lib/captain/runtime/agent_tool_texts_spec.rb spec/enterprise/lib/captain/runtime/tool_wrapper_spec.rb spec/enterprise/lib/captain/tool_registry_spec.rb spec/enterprise/lib/enterprise/captain/reply_suggestion_service/trace_collector_spec.rb spec/enterprise/models/captain/assistant_spec.rb spec/enterprise/services/captain/reply_suggestion/draft_times_spec.rb spec/enterprise/services/captain/reply_suggestion/searched_slots_spec.rb --format progress # base worktree
source ~/.test-env; POSTGRES_DATABASE=chatwoot_codex_speed bundle exec rspec -r /home/codex-e/vite_stub.rb spec/enterprise/lib/captain/assistant_prompt_spec.rb spec/enterprise/lib/captain/runtime/agent_tool_texts_spec.rb spec/enterprise/services/captain/assistant/agent_runner_service_generate_response_booking_flow_spec.rb --format progress
pnpm install --frozen-lockfile
pnpm exec vitest run app/javascript/dashboard/composables/spec/suggestionStages.spec.js app/javascript/dashboard/i18n/specs/translationKeys.spec.js
pnpm exec vitest run app/javascript/dashboard/i18n/specs/translationKeys.spec.js --reporter=dot # base worktree
pnpm exec eslint app/javascript/dashboard/composables/captain/suggestionStages.js app/javascript/dashboard/composables/spec/suggestionStages.spec.js app/javascript/dashboard/i18n/specs/translationKeys.spec.js
pnpm exec prettier --check app/javascript/dashboard/composables/captain/suggestionStages.js app/javascript/dashboard/composables/spec/suggestionStages.spec.js app/javascript/dashboard/i18n/locale/kk/integrations.json
bundle exec rubocop enterprise/app/services/captain/reply_suggestion/faq_preload.rb enterprise/app/services/captain/tools/account/search_booking_options_service.rb spec/enterprise/services/captain/reply_suggestion/faq_preload_spec.rb spec/enterprise/services/captain/tools/account/search_booking_options_service_spec.rb spec/enterprise/lib/captain/assistant_prompt_spec.rb spec/enterprise/lib/captain/runtime/agent_tool_texts_spec.rb
ruby -c enterprise/app/services/captain/reply_suggestion/faq_preload.rb && ruby -c enterprise/app/services/captain/tools/account/search_booking_options_service.rb && ruby -c spec/enterprise/services/captain/reply_suggestion/faq_preload_spec.rb && ruby -c spec/enterprise/services/captain/tools/account/search_booking_options_service_spec.rb && ruby -c spec/enterprise/lib/captain/assistant_prompt_spec.rb && ruby -c spec/enterprise/lib/captain/runtime/agent_tool_texts_spec.rb
ruby -e "require 'yaml'; YAML.load_file('config/captain/agent_tool_texts.yml'); puts 'YAML OK'"
python3 -m json.tool app/javascript/dashboard/i18n/locale/kk/integrations.json >/dev/null
git diff --check
```
