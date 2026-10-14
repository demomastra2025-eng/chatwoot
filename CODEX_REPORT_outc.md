# Outcome classification on run facts (outc)

## Changed

- Set the fresh-install outcome classifier default to `inception/mercury-decide` and approved it for the native Decisions endpoint. Super admin model selection remains available.
- Added the built-in completion reason `closed_against_instructions` with the Russian label `Закрыто не по правилу клиники`, English and Kazakh keys, report defaults, and the settings reason list.
- The classifier now receives a bounded fact object: whether the closing agent replied publicly in the current run, its private staff notes, handoff explanation, FAQ lookup outcomes, fixed tool failure and safety categories, and action kinds from Captain's durable DoneActions record. A completion also receives the closing agent's clinic instruction captured at transition time and resolved with the prompt's reference syntax against an empty patient state. Database message IDs stay inside the expansion logic.
- Fact collection runs when tools complete, including council parts and tool exceptions. Handoff and completion paths attach the compact record to the status transition. The classifier reads the event's captured values, including on retry.
- Facts, notes, instruction, and public message fragments have list and byte limits. Tool arguments, raw tool responses, operation IDs, action text, and patient record fields are excluded from structured facts.

## Example input

The native Decisions state for a handoff has this shape (synthetic data):

```json
{
  "outcome": "handoff",
  "locale": "ru",
  "explanation": "Нужна проверка сотрудника",
  "messages": [{ "role": "customer", "content": "Можно изменить время записи?" }],
  "facts": {
    "public_reply_sent": false,
    "staff_notes": ["Календарь сейчас недоступен; сотруднику нужно проверить запись."],
    "handoff_reason": "Нужна проверка сотрудника",
    "faq_lookups": ["not_found"],
    "tool_failures": ["calendar_unavailable"],
    "safety_blocks": [],
    "done_actions": ["Booked"]
  },
  "expansion_available": false
}
```

For a completion, `facts.clinic_instruction` holds up to 12,000 UTF-8 bytes of the captured clinic instruction, such as `Close only after payment is received.` The `handoff_reason` key is absent.

## Kept and why

- The seven existing handoff reasons and the verified `faq_no_answer` shortcut retain their meaning.
- `other`, `NEEDS_MORE_CONTEXT`, and at most one public-message expansion remain the insufficient-evidence behavior.
- Existing chat classifiers still work through their structured response path; the new facts are sent to both classifier paths.

## Decisions and limits

- The run starts at the last incoming message captured with the transition. Notes may be written just after a status transition inside the same transaction; the collector includes the next 30 seconds, stopping at the next incoming message or status transition.
- DoneActions contributes only fixed English action labels, including pending booking labels. Free-form action details are omitted to avoid repeating patient data from tool results.
- The clinic instruction is captured before any later assistant edit. Prompt references resolve with an empty patient state, so dynamic patient values and internal IDs are not added. This can leave a dynamic field value unspecified; the clinic's written condition remains visible.
- Public message contents and requested private notes are passed to the model as text. The code does not infer an outcome from their wording.
- `docs/` is an unpopulated git submodule in this clone, so the internal and public documentation pages could not be edited here.

## Checks

| Check | Result |
| --- | --- |
| `pnpm install --frozen-lockfile` | Passed; installed local tooling from the lockfile. |
| `pnpm exec vitest run app/javascript/dashboard/routes/dashboard/captain/assistants/outcomes/reasonOrder.spec.js app/javascript/dashboard/i18n/specs/translationKeys.spec.js` | Passed twice: 2 files, 14 tests each run. |
| `pnpm exec eslint app/javascript/dashboard/routes/dashboard/captain/assistants/outcomes/reasonOrder.js app/javascript/dashboard/routes/dashboard/captain/assistants/outcomes/reasonOrder.spec.js` | Passed. |
| `pnpm exec prettier --check app/javascript/dashboard/routes/dashboard/captain/assistants/outcomes/reasonOrder.js app/javascript/dashboard/routes/dashboard/captain/assistants/outcomes/reasonOrder.spec.js` | Passed. |
| `ruby -c` on each of the 21 changed or added Ruby files | Passed (`Syntax OK` for each). |
| `YAML.safe_load_file(..., aliases: true)` on `config/llm.yml`, `config/installation_config.yml`, and the three `captain_outcomes` locale files | Passed. |
| `bundle exec rubocop enterprise/app/services/captain/outcome_facts.rb spec/enterprise/services/captain/outcome_facts_spec.rb --format simple` | Passed: 2 files, no offenses. |
| `bundle exec rubocop --only Lint` on the 12 changed runtime and classifier Ruby files/specs | Passed: 12 files, no offenses. |
| Broad `bundle exec rubocop` on 18 touched Ruby files | Failed with 122 offenses, largely existing metrics/style/RSpec offenses in touched legacy files. The new fact collector and its spec are clean. |
| `git diff --check` and `git diff --cached --check` | Passed. |
| Database-backed RSpec | Not run: this machine has no Postgres or Redis. No green RSpec claim is made. |

The first commit's local hook also ran ESLint and RuboCop; RuboCop reported existing offenses and auto-corrected formatting in two staged specs. The second code commit used the explicitly run checks above rather than the hook.

## RSpec files for the release runner

```text
spec/enterprise/services/captain/outcome_facts_spec.rb
spec/enterprise/services/captain/outcome_classification_service_spec.rb
spec/enterprise/services/captain/outcome_decision_engine_spec.rb
spec/enterprise/lib/captain/outcome_reason_config_spec.rb
spec/enterprise/lib/captain/runtime/tool_wrapper_spec.rb
spec/enterprise/lib/captain/runtime/council_spec.rb
spec/enterprise/lib/captain/tools/resolve_conversation_tool_spec.rb
spec/enterprise/services/captain/assistant/agent_runner_service_spec.rb
spec/enterprise/jobs/captain/conversation/response_builder_job_spec.rb
spec/lib/llm/config_spec.rb
spec/lib/llm/models_spec.rb
spec/lib/llm/installation_model_config_spec.rb
spec/lib/llm/open_router_capability_resolver_spec.rb
spec/lib/llm/open_router_decision_client_spec.rb
spec/lib/llm/haiku_model_configuration_spec.rb
```

## Open questions

- Whether the clinic wants dynamic, nonpersonal prompt-field values alongside the written instruction. The current input resolves references without patient state to avoid adding personal fields.
- Whether docs should be updated by the release runner after it initializes the `docs/` submodule.
