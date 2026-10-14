# Workspace settings release E report (`ws`)

Branch: `codex/ws`. Implementation commits: `e9bd03acd`, `299fcdd03`, `cd7cc49dc`. No remote was added or used, and no production system was accessed.

## What changed

### A. Clinic schedule

- Added an account schedule with a time zone, seven weekly entries, breaks, and days off. Without a saved schedule, open-now checks treat the workspace as always open. Inbox open/closed checks, reminder delivery, response-time weekly hours, and dashboard/public inbox payloads use the workspace schedule.
- Added the Russian **Рабочие часы** card to workspace settings and removed the channel working-hours page. New scheduling specialists inherit the workspace schedule; existing specialists retain personal schedules. A personal schedule overrides workspace days off. Inheriting specialists receive account schedule updates.
- Ported the relevant `aset/dev` model, schedule card, inheritance migrations, and specialist behavior. The reference patch's inbox schedule synchronization and old per-inbox enable switch were intentionally not ported because the owner removed channel schedules. Unrelated consolidation hunks were not ported.

### B. Staff on every channel

- Backfilled missing account-user/inbox memberships, including voice inboxes. New account users and new inboxes fill membership idempotently. Legacy membership removal requests keep workspace memberships and return normally.
- Removed the channel collaborators page and staff selection from text/Twilio setup. The virtual PBX step remains for assigning a specific SIP profile and extension to a user; it no longer writes inbox membership or selects every account user by default. Telephony profile and phone assignment logic remains in place.

### C. Workspace assignment

- Added the workspace auto-assignment switch beside the workspace assignment policy. Scheduled and conversation assignment use the workspace switch and selected policy. Channel assignment controls were removed from the UI. Historical inbox columns and policy links remain stored for compatibility.
- Admin Copilot settings tools now write/read the workspace assignment policy and switch; their legacy inbox-shaped responses report effective workspace values.

### D. Text AI routing

- Every active external agent is available on every text channel. One active main agent, shown with a star and **Главный**, is the entry agent. A starred agent cannot be switched off. Voice routing remains on its existing path.
- Replaced the per-agent/channel matrix with one **ИИ отвечает** switch per text channel, and added the workspace **ИИ отвечает клиентам** emergency switch and one reply-time mode. Working-time modes require a configured workspace schedule. A new text inbox gets AI enabled when a main agent exists. Playground starts from the workspace main agent; without a selected channel it works alone.
- Runtime entry resolution, peers, and reply-time checks use these workspace settings. Old agent-channel links and per-inbox reply modes remain stored but are not used for text routing. Admin Copilot readers and the text reply-time writer use effective workspace values.

## Production-fact migration behavior

| Area | Behavior for the supplied production facts |
| --- | --- |
| Schedule | From 69 inboxes, each account with an enabled schedule copies the first complete seven-day enabled inbox schedule and time zone. The 3 enabled inboxes have no conflicting account schedules. Accounts with no enabled schedule remain unscheduled and open for open-now checks. Old inbox hours are retained. |
| Staff | Inserts the 196 missing memberships across 140 account users and 69 inboxes using `ON CONFLICT DO NOTHING`. Re-running does not duplicate rows. SIP profile ownership is not changed. |
| Assignment | For each account, the majority of its inbox values sets workspace auto-assignment; a tie selects on. The supplied 55-on/14-off distribution is applied per account, not globally. Each account's linked policy is copied; the 2 links do not conflict within an account. Old columns and links are retained. |
| AI | `captain_inboxes.ai_enabled` already exists in this branch's schema. For the 7 accounts with 10 linked text channels, linked channels become on and unlinked existing text channels remain off. When entry agents differ, the migration counts distinct handled conversation IDs from message sender identifiers only and selects the most-used active external linked agent. With no linked AI channel it selects the oldest active external agent, or none. It does not read message content. An account marker prevents a rerun from undoing later switch changes. Accounts with no eligible agent retain their other settings. |

All migrations preserve historical rows and have safe repeat behavior. No data deletion or finding suppression was added. `config/brakeman.ignore` was not edited.

## Checks

| Check | Result |
| --- | --- |
| `bundle check` | Passed. |
| `pnpm install --frozen-lockfile` | Passed; installed local frontend dependencies. |
| `ruby -c` over changed Ruby files | Passed at each iteration (43, 63, and 66 files); final pass: 66 files, zero syntax failures. |
| `pnpm exec vitest run` on the 14 focused frontend specs below with `--reporter=dot` | **Passed: 14 files, 169 tests.** The translation-key guard passed. |
| `pnpm exec eslint --format json` on 22 changed JS/Vue files | Passed: zero errors, 625 warnings. Most warnings are existing localization-key checks on large Vue pages. |
| `pnpm exec prettier --check` on 32 changed JS/Vue/JSON files | Passed. Several `prettier --write` formatting passes also succeeded. |
| `bundle exec rubocop --format json` on 11 new Ruby files | Passed: zero offenses. |
| `bundle exec rubocop --format json` on all 66 changed Ruby files | Exit 1: 5,963 total offenses in touched large/legacy files. The added-line audit found only 3 generated `db/schema.rb` formatting offenses; no added implementation line had an offense. The commit hook ran its `rubocop --fail-level E` gate successfully for all three code commits. |
| `git diff --check` and the commit hooks | Passed. Final committed implementation tree is clean. |

Intermediate checks were also recorded: the first focused Vitest run failed on stale matrix/settings test setup, then focused reruns passed 42 and 47 tests; a broader page run passed 45 tests. The first voice setup run had one obsolete route expectation among 81 tests; after updating it, the 7-file focused run passed 70 tests, followed by the final 169-test run. ESLint first included a deleted file path, then found 24 formatting errors, later one formatting error; all were fixed before its final zero-error run. New-file RuboCop went from 6 offenses, to 1, to zero. An early all-changed-file RuboCop run reported 6,008 offenses before the refactors and hook formatting; the final count is above.

Final Vitest files:

```text
app/javascript/dashboard/routes/dashboard/settings/account/components/WorkspaceWorkingHours.spec.js
app/javascript/dashboard/routes/dashboard/settings/account/components/WorkspaceAssignmentPolicySettings.spec.js
app/javascript/dashboard/routes/dashboard/settings/account/Index.spec.js
app/javascript/dashboard/routes/dashboard/settings/inbox/Settings.spec.js
app/javascript/dashboard/routes/dashboard/settings/inbox/AddAgents.spec.js
app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Voice.spec.js
app/javascript/dashboard/routes/dashboard/settings/inbox/noAiAgentAssignment.spec.js
app/javascript/dashboard/routes/dashboard/scheduling/pages/SchedulingResourcesPage.spec.js
app/javascript/dashboard/routes/dashboard/captain/channels/Index.spec.js
app/javascript/dashboard/routes/dashboard/captain/aiSettings/Index.spec.js
app/javascript/dashboard/routes/dashboard/captain/agents/Index.spec.js
app/javascript/dashboard/routes/dashboard/captain/agents/AgentPage.spec.js
app/javascript/dashboard/components-next/captain/agent/AgentGalleryCard.spec.js
app/javascript/dashboard/i18n/specs/translationKeys.spec.js
```

**RSpec was not run:** this machine has no Postgres or Redis. The release orchestrator should run these files:

```text
spec/controllers/api/v1/accounts/inbox_members_controller_spec.rb
spec/controllers/api/v1/accounts_controller_spec.rb
spec/enterprise/controllers/api/v1/accounts/captain/channel_matrix_controller_spec.rb
spec/enterprise/migrations/unify_workspace_staff_and_assignment_spec.rb
spec/enterprise/models/captain_inbox_spec.rb
spec/enterprise/services/captain/agent_graph_spec.rb
spec/enterprise/services/captain/playground/session_spec.rb
spec/enterprise/services/captain/tools/copilot/get_inbox_settings_service_spec.rb
spec/enterprise/services/captain/tools/copilot/list_inboxes_service_spec.rb
spec/enterprise/services/captain/tools/copilot/set_inbox_assignment_policy_service_spec.rb
spec/enterprise/services/captain/tools/copilot/update_captain_inbox_auto_reply_mode_service_spec.rb
spec/enterprise/services/captain/tools/copilot/update_inbox_settings_service_spec.rb
spec/enterprise/services/captain/tools/copilot/update_inbox_working_hours_service_spec.rb
spec/helpers/reporting_event_helper_spec.rb
spec/jobs/auto_assignment/periodic_assignment_job_spec.rb
spec/migrations/add_workspace_working_hours_inheritance_to_inboxes_spec.rb
spec/models/account_user_spec.rb
spec/models/concerns/account_workspace_working_hours_spec.rb
spec/models/inbox_spec.rb
spec/models/scheduling/resource_workspace_hours_spec.rb
spec/services/reminders/delivery_window_policy_spec.rb
spec/services/scheduling/resource_schedule_service_spec.rb
```

## Open risks and questions

- Database migrations, backfills, request specs, and runtime integration still require verification in the release environment with Postgres and Redis. `db/schema.rb` was updated without a local database; compare generated schema after migration.
- If a workspace has no active main agent, a new text channel cannot create an AI link and stays effectively off until an agent is starred. Should the first later-activated agent be starred automatically?
- The response-time business-hours metric uses the workspace weekly hours but does not subtract workspace breaks or days off. Should that historical metric change in this release?
- Legacy inbox APIs can still store the retained per-inbox hours/assignment values. Runtime and new UI ignore them. Should a future release reject or silently ignore those writes?
- The `docs/` submodule is empty in this local clone and no remote is available. The internal note is [script/onelink/WORKSPACE_SETTINGS.md](script/onelink/WORKSPACE_SETTINGS.md); client-facing docs in the docs repository still need synchronization before release.
