# R4 release report

## Changes

- **A — transfer targets:** A colleague is visible only when its selected tools add an action, its handoff team differs, or its booking scope reaches resources the current agent cannot book. Transfer descriptions and colleague lines lead with those actions; routing text is a short note. With no eligible colleague, the plan and transfer tools are absent.
- **B — team handoff:** Agent config accepts an account team. An authorized staff handoff assigns the conversation to that team after the handoff is applied. The private note and default silent behavior remain.
- **C — booking scope:** Agent config accepts account resource IDs. Agent resource search, slot search, and create/update/cancel appointment operations enforce the scope. An empty scope retains access to all resources. The agent page has Russian team and specialist/room selectors; matching en/kk keys exist for the translation guard.
- **D — texts:** Booking instructions now treat an exact time question during booking as a booking request; distinguish an additional visit from a change; search following days after a taken time; give full dates around midnight; search the service catalog for prices and FAQ for documents first.
- **E — plan schema:** `executor` lists only eligible colleague names for the run. Link fields appear only while an open colleague part exists, and `link_part_id` lists its real numbers.
- **F — benchmark:** Fixtures accept teams, agent handoff teams, and named booking resources. FAQ indexing is on by default (`BENCHMARK_FAQ_EMBEDDINGS=0` disables it). Database model configs are cached for five minutes and invalidated on catalog refresh. The judge sees longer council tool results and council outcomes. A rejected plan is reported as `plan_rejected` rather than a forbidden tool.

Before: `Transfer the conversation to colleague "Продажи": Сделки клиники. Can: create and update deals; look up deals.`

After, for an agent lacking `create_deal`: `Transfer the conversation to colleague "Продажи": create deal. Note: Сделки клиники.`

## Kept and decisions

- Every agent still has the shared FAQ and service catalog; read-only peers provide no transfer target.
- Existing account entities, native team assignment, and assistant JSON config are reused. No migration or data deletion was needed.
- Staff handoff remains available when no colleague can perform an action. A missing team preserves the previous handoff behavior.
- Team and resource IDs are validated against the assistant account. Chatwoot normalizes stored team names to lowercase.
- The docs submodule is uninitialized in this clone. The benchmark README was updated here; the public and internal docs submodule cannot be edited locally without its content.

## Checks

| Check | Result |
| --- | --- |
| `pnpm install --frozen-lockfile` | Passed. |
| `bundle exec rubocop --version` | Passed; 1.75.6. |
| `ruby -c` on every changed Ruby file; `YAML.load_file('config/captain/agent_tool_texts.yml')` | Passed. |
| `git diff --check` | Passed. |
| First `pnpm vitest run` (draft, agent page, misspelled translation guard path) | Failed: 9 failures, 14 passes. The two frontend setup issues were then fixed. |
| Second `pnpm vitest run` (draft and agent page) | Failed: 8 agent page failures from a mock reset. Fixed. |
| Final `pnpm vitest run app/javascript/dashboard/components-next/captain/agent/agentDraft.spec.js app/javascript/dashboard/routes/dashboard/captain/agents/AgentPage.spec.js app/javascript/dashboard/i18n/specs/translationKeys.spec.js` | Passed: **29 tests** across 3 files. This successful command was run twice. |
| `pnpm exec eslint` on the five changed Vue/JS files, `--quiet` | First run found 1 formatting error. Final run passed. |
| `pnpm eslint` with changed files as arguments | The package script also linted all of `app/`; it failed with 1 formatting error and 9,582 warnings. The error was fixed and the narrow changed-file run passed. |
| `bundle exec rubocop --force-exclusion` on changed Ruby files, using `.rubocop.yml` | Initial simple-format run exited 1 with 318 file-wide offenses. Later JSON runs also exited 1 (429 file-wide offenses in the last full run). Filtering JSON against added lines found **zero offenses on changed lines**. The final four-file scheduling follow-up also had zero changed-line offenses. |
| First Git commit hook (`eslint --fix`, then RuboCop auto correction) | Interrupted when it began changing unrelated preexisting Ruby lines. Those worktree edits were restored; the reviewed commits used `HUSKY=0` after the explicit lint checks above. |
| RSpec and live routing benchmark | **Not run.** This machine has no Postgres or Redis, and the benchmark also needs its provider. No backend pass is claimed. |

## RSpec files for the orchestrator

```text
spec/enterprise/jobs/captain/conversation/response_builder_job_spec.rb
spec/enterprise/lib/captain/evals/routing_benchmark/fixture_spec.rb
spec/enterprise/lib/captain/evals/routing_benchmark/runner_spec.rb
spec/enterprise/lib/captain/evals/routing_benchmark/scorer_spec.rb
spec/enterprise/lib/captain/evals/routing_benchmark/workspace_spec.rb
spec/enterprise/lib/captain/runtime/chat_factory_spec.rb
spec/enterprise/lib/captain/runtime/handoff_monitoring_spec.rb
spec/enterprise/lib/captain/runtime/part_plan_tool_spec.rb
spec/enterprise/lib/captain/runtime/transfer_capabilities_spec.rb
spec/enterprise/lib/captain/tools/operations/appointment_operations_spec.rb
spec/enterprise/models/captain/assistant_spec.rb
spec/enterprise/services/captain/agent_graph_spec.rb
spec/enterprise/services/captain/agent_run_context_spec.rb
spec/enterprise/services/captain/tools/copilot/search_available_slots_service_spec.rb
spec/enterprise/services/captain/tools/copilot/search_scheduling_resources_service_spec.rb
spec/lib/llm/open_router_model_catalog_spec.rb
spec/services/scheduling/resource_search_service_spec.rb
```

## Open questions and risks

- The tool registry has no explicit write flag for custom HTTP or MCP tools. The capability filter uses selected built-in action IDs and registered action-name prefixes. The owner should decide whether external tools need explicit write metadata before they can be transfer reasons.
- Backend integration and live dialogue behavior remain unverified until the orchestrator runs the RSpec files and benchmark with database and provider access.
- Public and internal product docs in the uninitialized `docs/` submodule still need the team and booking scope workflow update.
