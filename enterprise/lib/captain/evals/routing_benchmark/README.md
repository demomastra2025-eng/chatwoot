# Captain routing benchmark

This harness creates synthetic accounts in an isolated PostgreSQL database, runs
customer turns through `Captain::Assistant::AgentRunnerService` and the native
runner/tools path, reads the resulting database rows and monitoring events, and
rolls back each fixture run. It never sends a channel reply. The synthetic API
inbox has no webhook. A playground marker on contacts and conversations makes
`Outbound::PlaygroundDeliveryPolicy` block external delivery and provider writes.
The account and conversation markers also keep benchmark rows out of customer
reports. No cleanup query or permanent fixture row is used.

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

## YAML fixture

Keys shown below define the supported schema. Every turn needs an expectation.
Agent names and fixture keys must be unique. Timestamps must include an ISO-8601
offset. `model`, when present on an agent, must be `openai/gpt-6-luna`; the CLI
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

## Monitoring contract

The existing AI Agents report response adds `payload.coordination` with
`transfers` (each has `from_agent_id`, `to_agent_id`, `conversation_id`,
`request_id`, and `staff_handoff_same_request`) and `guard_count`. The report
includes only live events. The runtime persists `captain.agent.transfer`,
`captain.agent.transfer_guard`, `captain.agent.return`, and
`captain.agent.reset` with `run_source`. The council event contract is
`captain.council.started` / `captain.council.finished` with participant IDs
and an outcome on finish; a future council runtime will call these producers.
