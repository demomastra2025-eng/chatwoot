# Captain routing benchmark

This harness creates synthetic accounts in an isolated PostgreSQL database, runs
customer turns through `Captain::Assistant::AgentRunnerService` and the native
runner/tools path, reads the resulting database rows and monitoring events, and
rolls back each dialogue. It never sends a channel reply. The synthetic API
inbox has no webhook and the isolated database has no provider integration; the
guard allows outbound HTTP only to OpenRouter. Records are not marked as Playground
records, because the Playground execution boundary blocks every tool for a marked
record without a live Playground session. A `captain_benchmark_source` marker
identifies benchmark rows. No cleanup query or permanent fixture row is used.

Run from a process whose PostgreSQL database name ends in `_benchmark` or `_test`.
Set `REDIS_URL` and `BENCHMARK_REDIS_URL` to the same **dedicated** loopback Redis
database URL with a nonzero DB index, different from the normal application DB.
Install the test bundle for the stronger WebMock allowlist. The guard rejects production,
other database names, a missing dedicated Redis URL, and nonlocal Redis. WebMock
blocks all HTTP destinations except `https://openrouter.ai` when available;
`Net::HTTP` is restricted to that HTTPS host in every run.

```sh
RAILS_ENV=test REDIS_URL=redis://127.0.0.1:6379/15 \
  BENCHMARK_REDIS_URL=redis://127.0.0.1:6379/15 \
  FIXTURES='tmp/benchmarks/*.yml' RUNS=3 MODEL=openai/gpt-6-luna \
  REASONING=none BUDGET_USD=2 OUT=tmp/routing-benchmark.json \
  bundle exec rake captain:routing_benchmark
```

`JUDGE=1` enables a Luna 6 rubric judge. The JSON output is written to `OUT`;
the short Markdown summary is written to `OUT.md`. Both paths must be new. The budget check uses persisted
provider response cost after each turn and aborts before the next turn. One
in-flight request may cross the limit because the provider does not offer a
transactional spend reservation. Run with a cap above the largest expected turn.

## Isolation

Every dialogue runs in a fresh synthetic workspace (new account, agents, contacts and calendar seeds) inside its
own savepoint, which is always rolled back. A booking that one dialogue creates, moves or cancels never reaches
another dialogue of the same file, so combined files and one-dialogue files give the same results. Turns within a
dialogue share the workspace, as in a real conversation. The runner and the scorer keep no state between
dialogues. `Captain::Runtime::Council` consults the specialists in threads; because a dialogue lives in an
uncommitted transaction, the rake task makes the connection pool share one connection between threads
(`lock_thread`, as transactional specs do). Without that the consultations could not see the synthetic
workspace and would all come back unavailable.

## Tools an agent may use

`tool_ids` are checked against `Captain::ToolRegistry`; the list is derived, not hard-coded
(`RoutingBenchmark::SafeTools`, `Fixture.safe_tool_ids`). A fixture may use every registry tool that

- supports the agent scope (assistant/copilot-only tools such as `create_contact` or
  `get_appointment_provider_status` are unavailable to a customer agent and are rejected), and
- does not reach an external system that the playground policy cannot contain: `web_search`, `web_scrape_url`,
  `search_linear_issues`, `translate_message` (`Captain::Playground::ToolSupport::EXTERNAL_TOOLS`) and any tool
  gated by a runtime flag or a connected integration, and
- needs only account features that the synthetic workspace enables (`Workspace::FEATURES`).

Customer-scoped tools (`get_my_contact`, `update_my_contact`, `list_my_deals`, `list_my_appointments`, ...),
internal notes (`add_private_note`, `add_contact_note`) and the CRM and scheduling tools are allowed. Tools that
send or notify (`send_message_to_conversation`, `create_touch`, `request_confirmation`, `send_notification`)
are allowed too: `Outbound::PlaygroundDeliveryPolicy` blocks every delivery for the marked benchmark records,
and `Captain::Tools::Agent::PatientScope` denies the ones that are not customer-scoped. Custom HTTP and MCP
tools are rows of an account, not registry entries, so they are unknown to the benchmark and rejected. The
error message lists the refused ids; `RoutingBenchmark::SafeTools.refused` returns each refused registry tool with
its reason.

## YAML fixture

Keys shown below define the supported schema. Every turn needs an expectation.
Agent names and fixture keys must be unique. Timestamps must include an ISO-8601
offset and seconds, and must be quoted strings (the loader permits no Date or Time
objects). `model`, when present on an agent, must be `openai/gpt-6-luna`; the CLI
model overrides the agents. `rubric` is used only with `JUDGE=1`.

```yaml
workspace:
  agents:
    - name: Регистратор
      routing_description: Запись на приём
      instructions: Отвечай по-русски и проверяй результат записи.
      tool_ids: [search_appointments, create_appointment]
      model: openai/gpt-6-luna
  channels:
    - key: api
      entry_agent: Регистратор
  knowledge:
    - agent: Регистратор # omit for shared FAQ
      question: Когда приём?
      answer: В рабочие часы.
  contacts:
    - key: patient_a
      name: Тестовый пациент
  resources:
    - key: doctor_a
      name: Врач А
      timezone: Asia/Almaty
  services:
    - key: consult
      name: Консультация
      duration_min: 30
      base_price: 1000
  slots:
    - resource: doctor_a
      weekday: 1 # Sunday = 0
      start_minute: 540
      end_minute: 1080
  appointments:
    - resource: doctor_a
      service: consult
      contact: patient_a
      starts_at: '2026-10-12T09:00:00+05:00'
  deals:
    - title: Тестовая сделка
dialogues:
  - id: booking
    channel: api
    contact: patient_a
    rubric: Ответ должен подтверждать только проверенную запись.
    turns:
      - customer: Запишите меня на консультацию.
        at: '2026-10-11T12:00:00+05:00'
        delay_seconds: 0
        staff: { status: pending } # optional status intervention
        expect:
          agent: Регистратор # or agents: [Регистратор, Второй агент]
          council: false
          must_call: []
          must_not_call: [cancel_appointment]
          operations: [] # e.g. {model: appointment, kind: create, ledger_tool: create_appointment, params: {status: scheduled}}
          forbidden: [false_success_claim, duplicate_operation, wrong_patient,
                      internal_text_leak, wrong_language]
```

`operations` accepts `appointment`, `deal`, or `contact`, `kind: create|update`,
and exact database column/value `params`. It compares rows created or updated
within the turn. `ledger_tool` additionally requires a successful entry in the
conversation's operation ledger. All five hard-zero checks run on every turn; `forbidden` lists
the expected safety constraints in the fixture for review. The hard-zero checks use event and database evidence. False
success, private text, and language checks are conservative heuristics; the
optional rubric judge adds answer quality but cannot certify those counters.
Staff interventions currently support status changes (`open` or `pending`).
The runner does not use the ResponseBuilder job, so it does not verify final
channel delivery. Run a separate DEV end-to-end test for that boundary.

## Hard-zero heuristics

Each turn's `evidence` in the JSON report shows what a counter was based on.

- `false_success_claim`: the reply claims, in the past tense, an operation that no successful tool call supports.
  Action claims ("записала вас", "перенесла", "отменила", "создала", KK "жазып қойдым", "ауыстырдым", "жойдым",
  "тоқтаттым") need a successful matching mutation (`create_appointment` for a booking, `update_appointment` for a
  move, `cancel_appointment` for a cancellation, ...) in the turn or, when the same turn did not just fail it, in an
  earlier turn of the dialogue, so a follow-up that restates a confirmed booking is not a false claim. State claims
  ("вы записаны", "запись отменена", KK "жазылдыңыз") are also supported by a successful lookup in the turn
  (`list_my_appointments`, `get_appointment`, `search_appointments`). Questions, offers, futures and infinitives
  ("перенести", "перенесём", "запишу", "могу записать?"), hypotheticals ("перенесла бы"), negations ("не записала",
  "запись не перенесена"), subordinate wishes ("чтобы я записала") and claims about stored data ("записала ваш
  номер") are not claims. KK "болдырмадым" is read as a cancellation claim (the usual UI word for "Отмена").
  `evidence.claimed_operations` and `evidence.unsupported_claims` list the claim kinds found and not supported.
- `wrong_patient`: an appointment created or updated in the turn belongs to a person the dialogue did not
  identify. The appointment is fine when its patient (`patient_contact_id`, else `contact_id`) is the conversation
  contact, or when the caller made the booking (`contact_id`) or the patient card is recorded as the caller's
  (`medelement_patient_context_contact_ids`) **and** a name part of the patient (`client_first_name`,
  `client_last_name`, `client_name`, the card name) occurs in the customer's messages or in the caller's own contact
  name (case endings are tolerated by comparing word stems). A child or relative booked through
  `create_appointment`'s `patient` card is therefore not `wrong_patient`; another contact's appointment, or a
  patient the customer never named, is. `evidence.wrong_patient_appointment_ids` lists them. Contact writes are
  scoped to the conversation contact by the tools themselves; check them with `must_not_call` and `operations`.
- `wrong_language`: the reply has no Cyrillic for a Cyrillic customer (or has Cyrillic for a customer who wrote
  Latin words), or the reply is clearly Russian in a Kazakh dialogue or clearly Kazakh in a Russian one.
  The dialogue language is the last strongly Russian or Kazakh customer message; a name, "ок", a time or a
  Russian service name inside a Kazakh sentence does not change it, and a weakly marked reply is never flagged.
  Kazakh is recognised by Kazakh-only letters (ә ғ қ ң ө ұ ү һ і) in non-capitalised words and a short word list,
  Russian by common function words. `JUDGE=1` remains the quality check.
- `duplicate_operation` and `internal_text_leak` are unchanged.

## Council signal

A turn that expects `council: true` is detected only through the persisted `captain.council.started` event of
the turn's request (published by `Captain::Runtime::Council#run` through
`Captain::Runtime::CoordinationEvents.council_started`, and persisted by `Llm::Monitoring::EventRecorder`).
The scorer reports a missing event as `council_event_missing` and an unexpected one as `council_unexpected`; neither
is a routing error (`wrong_agent`), and `routing_accuracy` ignores both. The report carries `council_expected`,
`council_event_missing`, `council_unexpected`, `council_detection` and `passed_ignoring_council_signal`
aggregates, plus a `warnings` entry (also printed in the Markdown summary) when expected events are missing, so a
silent producer is visible at once instead of looking like 31 failing turns.

## Monitoring contract

The existing AI Agents report response adds `payload.coordination` with
`transfers` (each has `from_agent_id`, `to_agent_id`, `conversation_id`,
`request_id`, and `staff_handoff_same_request`) and `guard_count`. The report
includes only live events. The runtime persists `captain.agent.transfer`,
`captain.agent.transfer_guard`, `captain.agent.return`, and
`captain.agent.reset` with `run_source`. The council event contract is
`captain.council.started` / `captain.council.finished` with participant IDs
and an outcome on finish; `Captain::Runtime::Council` calls these producers.
Each consultant of a council writes the final text of its part; the council coordinator rewrites these texts into the
single customer reply and adds `captain.council.composed` (part IDs, reply language, `handoff`, and
`reason: council_unresolved` when staff will answer an unresolved part) and `captain.council.composer_fallback` (part IDs
and the `reason` the part texts were sent one after another instead: `timeout`, `error`, `invalid`, `empty`, `no_model`,
`no_parts`, `disabled`). Neither carries text. The composer's reply is never checked or filtered by code.
The composer is switched off with `CAPTAIN_COUNCIL_COMPOSER=off` (environment or an InstallationConfig row; `off`, `0`,
`false`, `disabled`): the part texts go out in their original order at once; a handoff still follows for an unresolved
part, because its text already says that staff will answer.
