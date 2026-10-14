# r3notes report

## Changes

- Reviewed `b0defb6d6` and kept its three restored agent tools: `add_private_note`, `add_contact_note`, and `send_notification` are mentionable and bind from instruction references. `cancel_response` remains excluded. The tool chip row now also omits capability tools mentioned in older instruction text.
- Made Captain staff handoffs silent. The handoff tool, council handoff, failed turn, custom safety handoff, automatic completion handoff, and quota handoff now create a private staff note without a handoff notice or out-of-office message. Pending Captain conversations that open for staff outside the agent schedule also receive a note. Inbox templates still work for open conversations and inboxes without Captain.
- Combined council handoff details into one note when an unanswered part and an unreported action meet. The note and status transition use the existing locked handoff transaction; stale and repeated handoffs do not write another note.
- Passed the safety policy's reason code to the note writer. Moderation, prompt injection, and credential checks have short staff-facing reasons. Raw error text, stack traces, and internal IDs are not put in these notes. Model-supplied `safety_reason` is discarded.
- Kept the existing partial council answer: staff receives the unanswered part in one note, while answers already prepared for other parts remain patient-visible. No handoff notice is sent.

## Handoff paths

| Path | Note before? | Fixed? | Code and spec |
| --- | --- | --- | --- |
| Handoff tool | Yes when reason present; blank reason wrote none in direct operations | Blank reason gets one fallback note; silent | `enterprise/app/jobs/captain/conversation/response_builder_job.rb`, `enterprise/lib/captain/tools/operations/conversation_operations.rb`; `spec/enterprise/jobs/captain/conversation/response_builder_job_spec.rb`, `spec/enterprise/lib/captain/tools/operations/conversation_operations_spec.rb` |
| Council unresolved part or `staff_reason` | Yes, but a separate council note could make two | One combined note; no handoff notice | `ResponseBuilderJob`; `response_builder_job_spec.rb` |
| Tool failure | Yes, with tool/stage/reason codes | Kept the reason and made handoff silent | `ResponseBuilderJob`; `response_builder_job_spec.rb` |
| Model/runtime failed turn | Yes, generic generation failure | Kept one note and removed public notice | `ResponseBuilderJob`; `response_builder_job_spec.rb` |
| Transfer guard | The guard itself does not hand off; it resumes the agent, which can call handoff or end in a failed turn | Existing terminal paths use the single handoff/failed-turn note | `enterprise/lib/captain/runtime/runner.rb`; `spec/enterprise/lib/captain/runtime/runner_task_finalization_spec.rb`, `response_builder_job_spec.rb` |
| Moderation, prompt injection, credentials | Generic safety note | Reason code selects a plain-language note; silent | `enterprise/app/services/captain/assistant/agent_runner_service.rb`, `ResponseBuilderJob`; `spec/enterprise/services/captain/assistant/agent_runner_service_spec.rb`, `response_builder_job_spec.rb` |
| Custom safety rule | One note, but a configured public message could also be sent | One note, silent, including retry | `ResponseBuilderJob`; `response_builder_job_spec.rb` |
| Automatic completion evaluation handoff | One note | Kept; added fallback reason and removed notice/out-of-office message | `enterprise/app/jobs/captain/inbox_pending_conversations_resolution_job.rb`; matching job spec |
| Quota exhausted | No note | One note inside the fenced handoff; silent | `enterprise/app/services/enterprise/message_templates/hook_execution_service.rb`; matching service spec |
| Outside Captain schedule | No note | One note in the status transaction; silent | `HookExecutionService`; matching service spec |

## Kept and decisions

- Kept the WIP tool catalog and runtime binding changes after reviewing the base commit; they match the owner's three-tool decision and the existing assistant binding path.
- Kept existing handoff fences, assignment/status behavior, and the council's already prepared partial answer. No migration or data deletion was made.
- Kept the handoff notice settings and service definitions because removing stored configuration is outside this task; live Captain handoff paths no longer invoke them.
- The `docs/` submodule is uninitialized in this local clone. No docs commit or submodule pointer change was possible without fetching a separate repository.

## Checks run

| Check | Result |
| --- | --- |
| `pnpm install --frozen-lockfile` | Passed. |
| `pnpm vitest run app/javascript/dashboard/components/widgets/conversation/TagTools.spec.js app/javascript/dashboard/components-next/captain/agent/AgentToolChips.spec.js` | Passed when only `TagTools.spec.js` existed: 4 tests. |
| `pnpm vitest run app/javascript/dashboard/i18n/specs/translationKeys.spec.js` | Passed: 5 tests. |
| `pnpm vitest run app/javascript/dashboard/components-next/captain/agent/AgentToolChips.spec.js app/javascript/dashboard/components/widgets/conversation/TagTools.spec.js app/javascript/dashboard/i18n/specs/translationKeys.spec.js` | Passed: 10 tests in 3 files. |
| `pnpm exec eslint` on the four changed frontend files | First run failed on 3 formatting errors in the new spec; after Prettier, passed with 0 errors and 3 existing warnings in `AgentToolChips.vue`. |
| `pnpm eslint` with changed file arguments | Its package script expanded to the whole `app/` tree. Stopped after about 4.5 minutes; exit 143. The targeted ESLint command above completed. |
| `pnpm exec prettier --check` on changed frontend files | Passed. `prettier --write` formatted the new chip spec before the final check. |
| `ruby -c` on the 17 Ruby implementation/spec files from this task and the WIP commit | Passed for every file after the commit hook. |
| `bundle exec rubocop` on 9 handoff Ruby files | Exited 1: 80 offenses, mainly existing complexity and spec style findings. |
| `bundle exec rubocop` on the 5 WIP Ruby files | Exited 1: 36 existing offenses. |
| `bundle exec rubocop` on the handoff tool and its spec | Exited 1: 2 existing alignment offenses; the commit hook corrected them. |
| Final `bundle exec rubocop --format json` on 12 handoff Ruby files | Exited 1: 101 offenses before commit-hook layout correction. The JSON report had no offense whose start line was added by this task. |
| `bundle exec rubocop -a --only Layout/EmptyLines` on three changed specs | Passed; no remaining offenses for that cop. |
| Ruby commit hook (`rubocop --force-exclusion -a --fail-level E` per staged Ruby file) | Completed and committed; it corrected layout while still reporting existing complexity/spec-style offenses. |
| `git diff --check HEAD~2 HEAD` | Passed. |

### Backend specs not run

This machine has no Postgres or Redis, so Rails/Sidekiq RSpec examples could not run here. The affected files are:

- `spec/enterprise/jobs/captain/conversation/response_builder_job_spec.rb`
- `spec/enterprise/jobs/captain/inbox_pending_conversations_resolution_job_spec.rb`
- `spec/enterprise/lib/captain/tools/handoff_tool_spec.rb`
- `spec/enterprise/lib/captain/tools/operations/conversation_operations_spec.rb`
- `spec/enterprise/services/captain/assistant/agent_runner_service_spec.rb`
- `spec/enterprise/services/enterprise/message_templates/hook_execution_service_spec.rb`
- WIP specs: `spec/enterprise/lib/captain/tool_access_spec.rb`, `spec/enterprise/lib/captain/tool_registry_spec.rb`, `spec/enterprise/models/captain/assistant_spec.rb`

## Open questions

- Should a council suppress answers to completed parts whenever another part requires staff? This change preserves the existing partial-answer workflow and makes only the handoff itself silent.
- Should dormant handoff-notice settings and service code be retired in a separate product decision? They were kept to avoid changing stored configuration without authorization.
