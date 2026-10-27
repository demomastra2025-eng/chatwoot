# cx-integ-2 integration report

Base: `e7348da6c` on local branch `codex/cx-integ-2`. No remote, push, production system, or production data was used.

## What changed

Merged the reviewed branches in the requested order: `i2-notifui` (`8c8bac50e`), `i2-mobile` (`3a5c807c4`), `i2-speed` (`57c901d35`), and `i2-stream` (`ea756737b`). The result adds Calendar → Уведомления, phone conversation panels that open only on an explicit tap, faster Captain suggestion reads and booking search, and staff-only draft streaming. Follow-up commits adapt the avatar test fixture to the new shared panel composable (`c8d98205c`), keep streaming and step callbacks and slot evidence coherent (`9b1b13a5e`), retain the relative appointment token lookup when a patient's own visits are preloaded (`21b4d54b4`), update merged specs for the current Captain session and trace-scope APIs (`1e2ae3410`), preload channel suggestions with their routed agent (`199e57688`), align the merged runtime specs (`8b2b5857f`), and preserve default calendar ownership for old automation clients (`1f739402e`).

## Conflict decisions and behavior kept

- The appointment controller loads the account-scoped appointment for the new notifications endpoint. It keeps the existing show, update, cancel, and destroy actions; `create_conversation` was absent from this controller, so it was not added to the callback list.
- An older automation client does not send `calendar_managed`. The new controller initially assigned `nil` over the database's `false` default and returned 500 on create. It now stores `true` only when explicitly requested and keeps `false` for omitted or null input. The old create/update/clone request and new calendar-rule request specs pass together.
- Scheduling locale files retain the existing MedElement patient-search keys and add the notification-screen keys in ru, en, and kk. The English and Kazakh additions match keys used by the new screen. `db/schema.rb` is at `2026_10_27_170000`, matching the highest migration. All 338 migration files under `db/` and `enterprise/` have unique versions.
- The CRM conversation panel retains the existing person-dialog provider. Its unused UI-settings import was removed after the mobile panel change. Desktop panel preferences remain; phone panels require an explicit action for the current conversation.
- Captain keeps the current agent graph and its no-agent technical-failure path, the existing patient/relative appointment scope and access tokens, IIN and exact-slot rules, and operator approval cards. The speed branch adds a single combined booking search over the existing scheduling searches, patient and FAQ preload, and model-step counters. The prompt sends booking-option questions to the combined search while preserving the earlier same-day, patient identity, slot-evidence, and staff-handoff rules. Preloaded appointments do not replace `list_my_appointments` when a relative's access token is needed. Slot evidence now reads the combined result to depth seven; it does not add a second availability algorithm.
- The streaming branch adds an answer-delta callback alongside the step counter callback. The trace collector keeps the current `scope` agent catalog and creates the draft stream for the requesting staff user. Previews remain ephemeral, are cleared when a draft is withdrawn, and do not send patient messages or replace final result checks.
- The speed and streaming specs used obsolete `AgentSession(entry:)` and `TraceCollector(assistant:)` constructors from before the current release line. Their fixtures now use a conversation-scoped ephemeral session and a channel scope; all assertions of tool order, counters, and staff previews remain.
- The incoming suggestion preload still used `@assistant` in a channel run, but channel runs now have a scope and select their agent after routing. Preload now resolves the routed agent, uses its tool access and FAQ visibility, and does not share patient preload across council parts. A new channel-scope regression example covers this path.
- Existing appointment notification rules remain intact. Calendar ownership is represented by the new flag and explicit adoption task; the integration did not run adoption on real data. The `docs/` submodule is uninitialized in this clone, so its pages could not be updated. The incoming branch added `script/onelink/calendar_notifications.md` for operational detail.

## Checks run

| Check | Result |
| --- | --- |
| `bundle check` | Passed. |
| `pnpm install --frozen-lockfile` | Passed; installed missing `node_modules`. |
| `source ~/.test-env`; `POSTGRES_DATABASE=chatwoot_codex_integ2 pg_isready -q` | Passed. |
| `source ~/.test-env`; `POSTGRES_DATABASE=chatwoot_codex_integ2 bundle exec rails db:create db:schema:load` | Passed on a new local test database. No migration command was needed after schema load. |
| Same create/schema-load command for `chatwoot_codex_integ2_s1`, `_s2`, `_s3`, and `_focus` | Passed; isolated databases for the Ruby spec shards and focused reruns. |
| Ruby specs: all files under `spec/enterprise/lib/captain`, `spec/enterprise/services/captain`, `spec/services/scheduling`, `spec/services/reminders`, `spec/services/automation_rules`, plus automation rule, appointment, listener, calendar notification, adoption, trace collector, and changed LLM specs, using `bundle exec rspec -r /home/codex-e/vite_stub.rb` | Four isolated shards; results and pre-existing failures summarized below. |
| Initial unsharded Ruby command on the requested directories and selected request/model specs | 0 examples; two load errors before examples. `AssignUserToTeamService` and `ListTeamsService` are undefined in two unchanged account-tool spec files. They were excluded from the sharded run and are listed below. |
| Retry excluding those two files, before splitting into shards | Interrupted after 404 examples, 0 failures, to run the same selection in four isolated shards. |
| Ruby shard 0 on `chatwoot_codex_integ2` | 1,693 examples, 22 failures in 22m 41s. Nine streaming-runner failures came from an obsolete session fixture; its corrected spec passed in the focused 65-example batch. The other 13 failures are unchanged routing-benchmark, conversation-control concurrency, and reminder concurrency failures recorded on the base in `CODEX_REPORT_cx-integ-1.md`. |
| Ruby shard 2 on `chatwoot_codex_integ2_s2` | 1,282 examples, 23 failures in 14m 54s. One tool-text assertion expected the old wording; it passed in the focused 65-example batch after correction. The other 22 are the base-recorded image-history, incoming-concurrency, message-builder, playground-adapter, and safety-rule failures. |
| Ruby shard 3 on `chatwoot_codex_integ2_s3` | 1,641 examples, 30 failures, 1 pending in 19m 51s. One Calendar automation create failure was caused by a missing `calendar_managed` default in the merged controller; the corrected request specs passed as a focused 3-example run. The other 29 match base-recorded structured-schema, suggestion-routing, image, language-detector, inbox-settings, and reminder-concurrency failures. |
| Ruby shard 1 on `chatwoot_codex_integ2_s1` | The run stalled at `agent_runner_service_spec.rb` as it did in `cx-integ-1` and was interrupted. Its completed prefix had ten failure markers: two stale suggestion-prompt assertions and seven speed-branch specs corrected in focused reruns, plus the unchanged assistant-operations registry failure. The stalled runner file passed in isolation, 142 examples, 0 failures. |
| Remaining 84 shard-1 files on `chatwoot_codex_integ2_s1` | 1,076 examples, 50 failures in 14m 28s. The failed examples are the same base-recorded customer-notice (14), availability-snapshot (1), job image-description (1), response-rewrite (31), and reminder email-subject (3) examples. |
| Focused Ruby rerun of the merged multi-tool and trace-collector specs after updating their fixtures | 15 examples, 0 failures. `ruby -c` and RuboCop on those two spec files also passed. |
| Focused runtime/spec batch for booking flow, patient/FAQ preload, suggestion prompt, streaming runner, and tool texts | 65 examples, 0 failures before adding the final council no-preload assertion. |
| Focused patient/FAQ preload file after the final council assertion | 11 examples, 0 failures. |
| Isolated channel-scope suggestion preload regression example | 1 example, 0 failures, after creating the lazy assistant fixture. The first isolated attempt failed at fixture setup. |
| Focused request specs for old automation clients and new Calendar notification rules after the boolean-default fix | 3 examples, 0 failures. |
| Isolated `agent_runner_service_spec.rb` after the shard-1 stall | 142 examples, 0 failures in 3m 3s. |
| Broad Vitest selection covering conversation, Scheduling, Captain, ActionCable, and `translationKeys.spec.js` | First run: 1,171 passed, 7 failed across 2 files. After adapting the avatar test fixture: 1,175 passed, 3 failed across 1 file; the only remaining failures are the translation-key guard. |
| Focused Vitest on conversation header, sidebar, and CRM panel | 62 passed. Focused avatar and conversation box rerun: 10 passed. |
| `pnpm exec eslint` on the resolved CRM panel, avatar spec, notifications page, and Copilot editor | Exit 0, no errors, 48 warnings from existing i18n/style rules. |
| `pnpm exec prettier --check` on those Vue/spec files and all three resolved scheduling locale JSON files | Passed. |
| `ruby -c` on the six resolved Ruby files; JSON parse of the three scheduling locale files; YAML parse of `agent_tool_texts.yml`; `git diff --check` | Passed. |
| `bundle exec rubocop` on the six resolved Ruby files | Exit 1: initially 29 offenses, 26 after the integration cleanup. Remaining findings are existing class size, method complexity, and method length in Captain. `bundle exec rubocop --fail-level E` exits 0. |
| Migration version scan across `db/` and `enterprise/`; schema-version comparison | Passed: 338 unique versions; highest and schema version are `20261027170000`. |
| Added UI-string scan for `Touch` / `Касание` | No added UI string contains either forbidden word. Existing internal `touch.created_at` and `create_touch` identifiers remain for the reminder contract. |
| First-parent commit-message trailer audit and `git diff --check e7348da6c HEAD` | Passed for all integration commits before this report. |

The translation-key guard has the same known missing-key counts reported by the incoming branch reviews: ru 235, en 241, kk 108. Its known-missing list and tests were not changed. No finding was suppressed and no functionality test was deleted or weakened.

The Ruby shard failures above are counts from broad invocations made before the indicated focused fixes, not claims of a fully green broad suite. `CODEX_REPORT_cx-integ-1.md` records the matching baseline failure classes and example descriptions. The new integration failures were fixed and covered by focused reruns; no unrelated baseline test was changed to force a pass.

## Open questions and limits

- A separate localization cleanup is needed to make the pre-existing translation-key guard fully green. The new keys are present in all three locales.
- Confirm whether free-text notification buttons require a delivery contract, whether late visit-end follow-ups should be skipped by the existing policy, and whether custom appointment conditions should be editable on the Calendar screen. The incoming branch retains existing custom conditions when saving.
- Live provider timing and provider-specific streamed field order were not verified in this local clone. The stream waits for an explicit reply mode before showing text to staff; a mode emitted last delays the preview.
- The two unchanged account-tool spec files cannot load because their constants are absent from this branch's code. They need separate ownership review; the integration did not invent those services.
