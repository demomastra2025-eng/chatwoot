# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::Report do
  let(:scorer) { Captain::Evals::RoutingBenchmark::Scorer }
  let(:risky) do
    { 'fixture' => '/x/ws_mid__kazakh_mixed_01.yml', 'dialogue' => 'kazakh_mixed_01', 'run' => 1, 'turn' => 3, 'status' => 'fail',
      'reasons' => ['forbidden_tool:create_appointment', 'wrong_agent'],
      'failures' => [failure('forbidden_tool:create_appointment', 'create_appointment completed successfully'), failure('wrong_agent', 'acted: nil')],
      'evaluated' => %w[forbidden_tool:create_appointment wrong_agent false_success_claim], 'customer' => 'ок',
      'patient_text' => 'Сізді жаздым.', 'acting_agent' => 'Запись к врачу',
      'tool_calls' => [{ 'tool' => 'create_appointment', 'success' => true, 'arguments' => '{"resource_id":4}', 'result' => '{"success":true}' }],
      'expectation' => { 'agent' => 'Запись к врачу', 'must_not_call' => ['create_appointment'] },
      'db_delta' => [{ 'id' => 12, 'change' => 'updated', 'resource' => 'doctor_b', 'service' => 'consult', 'patient' => 'caller',
                       'starts_at' => '2026-10-15T12:00:00+05:00', 'previous' => { 'resource' => 'doctor_a', 'starts_at' => '2026-10-13T15:00:00+05:00',
                                                                                  'status' => 'scheduled' } }] }
  end
  # A turn that puts gate items a (a booking with its doctor, time and service) and f (a request for a person) to the test.
  let(:fine) do
    booking = { 'model' => 'appointment', 'kind' => 'create', 'resource' => 'doctor_a', 'service' => 'consult', 'starts_at' => '2026-10-15T12:00:00+05:00' }
    { 'fixture' => '/x/ws_mid__kazakh_mixed_01.yml', 'dialogue' => 'kazakh_mixed_01', 'run' => 1, 'turn' => 1, 'status' => 'pass', 'reasons' => [],
      'failures' => [], 'evaluated' => %w[wrong_agent false_success_claim], 'customer' => 'Сәлеметсіз бе', 'reply' => 'Сәлеметсіз бе!',
      'patient_text' => 'Сәлеметсіз бе!', 'expectation' => { 'operations' => [booking] }, 'human_request' => { 'value' => true, 'source' => 'fixture' } }
  end
  let(:cases) { [fine, risky] }
  let(:report) do
    {
      gate: Captain::Evals::RoutingBenchmark::Gate.call(cases),
      triage: Captain::Evals::RoutingBenchmark::Triage.records(cases),
      model: 'openai/gpt-6-luna', runs: 1, aborted: false, aborted_at_budget: false, cost_usd: 0.12, warnings: ['a warning'],
      cases: cases,
      aggregates: { total: 2, passed: 1, routing_accuracy: 0.5, council_detection: 1.0, council_expected: 0, council_event_missing: 0,
                    council_unexpected: 0, passed_ignoring_council_signal: 1, hard_zero: { 'false_success_claim' => 0 },
                    latency_p50_ms: 10, latency_p95_ms: 20 }
    }
  end
  let(:markdown) { described_class.new(report).markdown }

  def failure(id, detail = nil)
    { 'id' => id, 'check' => scorer.base_check(id), 'severity' => scorer.severity_for(id), 'gate' => scorer.gate_item_for(id),
      'detail' => detail }.compact
  end

  it 'starts with the GATE section: the verdict, the rules and the critical failures' do
    expect(markdown).to start_with("# Routing benchmark\n\n## GATE\n\n**Verdict: FAIL**")
    expect(markdown).to include('| Critical checks, all must pass | 2/3 passed (66.67%), 1 failed |')
    expect(markdown).to include('| Overall score, at least 95.0% | 1/2 turns passed (50.0%) |')
    expect(markdown).to include('| Run complete | yes |', '| Failed checks triaged by a person | 0/2 |')
    expect(markdown).to include('### Critical failures',
                                '- `kazakh_mixed_01` turn 3: `forbidden_tool:create_appointment` (gate a,c) create_appointment completed successfully')
  end

  it 'puts the GATE section before the summary and the triage list' do
    expect(markdown.index('## GATE')).to be < markdown.index('## Summary')
    expect(markdown.index('## Summary')).to be < markdown.index('## TRIAGE')
  end

  it 'keeps the summary lines of the first harness version' do
    expect(markdown).to include('Model: openai/gpt-6-luna; runs: 1; cases: 2; passed: 1.', 'Hard-zero counters: {"false_success_claim":0}.',
                                'Latency p50/p95: 10/20 ms.', 'WARNING: a warning')
  end

  it 'lists one triage record per failed check, critical first, with an empty triage field' do
    records = markdown[/## TRIAGE.*/m]

    expect(records).to include('2 failed check(s).')
    expect(records.index('critical - `kazakh_mixed_01` turn 3 - `forbidden_tool:create_appointment`')).to be < records.index('important - `kazakh_mixed_01` turn 3 - `wrong_agent`')
    expect(records).to include('- Patient: ок', '- Agent reply: Сізді жаздым.',
                               '- Tool calls: create_appointment args {"resource_id":4} -> {"success":true}',
                               '- Expectation: {"agent":"Запись к врачу","must_not_call":["create_appointment"]}',
                               '- Triage: ________ (agent_bug | test_bug | judge_error)')
  end

  it 'says whether the handoff of the run was silent, when the run checked it' do
    expect(markdown).not_to include('Handoff is silent')
    silent = report.merge(gate: Captain::Evals::RoutingBenchmark::Gate.call(cases, silent_handoff: true))
    loud = report.merge(gate: Captain::Evals::RoutingBenchmark::Gate.call(cases, silent_handoff: false))

    expect(described_class.new(silent).markdown).to include('| Handoff is silent (blank notice) | yes |')
    expect(described_class.new(loud).markdown).to include('| Handoff is silent (blank notice) | no |', 'the handoff notice of the synthetic account is not blank')
  end

  it 'shows what the run put to the test for each gate item' do
    expect(markdown).to include('### Coverage', '| a | 1 of 1 | appointment expectations that pin the start time (blocks the gate) |',
                                '| f | 1 | turns in which the customer asks for a person (blocks the gate) |')
  end

  describe 'the dialogues, the accuracies and the infrastructure failures' do
    let(:down) do
      risky.merge('dialogue' => 'down_01', 'turn' => 1, 'reasons' => ['technical_handoff'], 'failures' => [failure('technical_handoff', 'tool: create_appointment; stage: execution')])
    end
    let(:clean) { fine.merge('dialogue' => 'ok_01') }
    let(:cases_of_run) { [fine, risky, down, clean] }
    let(:summary) { Captain::Evals::RoutingBenchmark::Summary.call(cases_of_run) }
    let(:full) do
      report.merge(cases: cases_of_run, gate: Captain::Evals::RoutingBenchmark::Gate.call(cases_of_run),
                   triage: Captain::Evals::RoutingBenchmark::Triage.records(cases_of_run),
                   aggregates: report[:aggregates].merge(summary.except(:dialogue_summaries)), dialogue_summaries: summary[:dialogue_summaries])
    end
    let(:text) { described_class.new(full).markdown }

    it 'says in the gate section how many turns failed on the infrastructure under the agents' do
      expect(text).to include('Infrastructure failures (left out of the quality rates, still failed turns): 1 turn(s), {"technical_handoff":1}.')
    end

    it 'prints the accuracies, the dialogue totals, pass^k and the categories in a section of their own' do
      expect(text).to include('Accuracy without infrastructure failures: routing 0.0, transfers n/a, staff handoff n/a, acts n/a.',
                              'Dialogues: 1/3 passed on every turn; blocked turns: 0; pass^1: 1/3 (0.3333).')
      expect(text).to include('## Dialogues', '| Category | Dialogues passed | Turns passed |', '| kazakh_mixed | 0/1 | 1/2 |', '| ok | 1/1 | 1/1 |')
      expect(text.index('## Summary')).to be < text.index('## Dialogues')
      expect(text.index('## Dialogues')).to be < text.index('## TRIAGE')
    end

    it 'lists the dialogues that did not pass turn by turn, with the failed checks' do
      expect(text).to include('Failed turns by check: `forbidden_tool` 1, `technical_handoff` 1, `wrong_agent` 1.')
      expect(text).to include('Dialogues that did not pass (2; blocked = failed after an earlier failure it depends on):',
                              '- `kazakh_mixed_01`: t1 pass, t3 FAIL (first failure: turn 3, forbidden_tool, wrong_agent)',
                              '- `down_01`: t1 FAIL (first failure: turn 1, technical_handoff)')
      expect(text).not_to include('- `ok_01`')
    end

    it 'shows the transfers, the council parts and a silent handoff in the triage record of the turn' do
      coordinated = risky.merge('evidence' => { 'transfers' => [{ 'from' => 'Администратор', 'to' => 'Запись к врачу' }],
                                                 'council' => { 'parts' => [{ 'owner' => 'Запись к врачу', 'state' => 'done', 'acted' => true }], 'editor_fallback' => 'timeout' } },
                                'silent_handoff' => true)
      records = Captain::Evals::RoutingBenchmark::Triage.records([coordinated])

      text = described_class.new(report.merge(cases: [coordinated], gate: Captain::Evals::RoutingBenchmark::Gate.call([coordinated]), triage: records)).markdown

      expect(text).to include('- Transfers: Администратор -> Запись к врачу', '- Council: Запись к врачу: done (acted); editor fallback timeout',
                              '- Silent handoff: the conversation was handed to staff with no text for the patient')
    end
  end

  it 'shows the database changes of the turn in each triage record, and says so when there are none' do
    expect(markdown).to include('- Database changes: appointment 12 updated: doctor_b, consult, caller, 2026-10-15T12:00:00+05:00 ' \
                                '(was doctor_a, 2026-10-13T15:00:00+05:00, scheduled)')
    unchanged = fine.merge('failures' => [failure('wrong_agent', 'x')], 'reasons' => ['wrong_agent'], 'status' => 'fail')
    text = described_class.new(report.merge(cases: [unchanged], gate: Captain::Evals::RoutingBenchmark::Gate.call([unchanged]),
                                            triage: Captain::Evals::RoutingBenchmark::Triage.records([unchanged]))).markdown

    expect(text).to include('- Database changes: none')
  end

  it 'reports PENDING_TRIAGE when only the triage of a person is missing' do
    bad = fine.merge('dialogue' => 'bad', 'failures' => [failure('wrong_agent')], 'reasons' => ['wrong_agent'], 'status' => 'fail')
    cases = Array.new(20) { |index| fine.merge('dialogue' => "ok#{index}") } + [bad]
    pending = report.merge(gate: Captain::Evals::RoutingBenchmark::Gate.call(cases))

    expect(described_class.new(pending).markdown).to include('**Verdict: PENDING_TRIAGE**', '- 1 failed check(s) not triaged by a person')
  end

  it 'names the blockers, and says so when there are none' do
    expect(markdown).to include('Blockers:', '- 1 critical failure(s)', '- overall 50.0% is below 95.0%')
    clean = report.merge(gate: Captain::Evals::RoutingBenchmark::Gate.call([fine]), triage: [], cases: [fine])

    expect(described_class.new(clean).markdown).to include('**Verdict: PASS**', 'No blockers.', '### Critical failures', 'None.')
  end

  it 'shows a stopped run' do
    stopped = report.merge(aborted: true, abort_reason: 'budget_reached')

    expect(described_class.new(stopped).markdown).to include('| Run complete | no, stopped: budget_reached |')
  end

  it 'reads a report loaded from JSON as well' do
    loaded = JSON.parse(JSON.generate(report))

    expect(described_class.new(loaded).markdown).to eq(markdown)
  end

  it 'shows a decided triage record and the verdict after triage' do
    labels = { Captain::Evals::RoutingBenchmark::Triage.key('ws_mid__kazakh_mixed_01.yml', 'kazakh_mixed_01', 3,
                                                            'forbidden_tool:create_appointment') => 'test_bug' }
    decided = report.merge(gate: Captain::Evals::RoutingBenchmark::Gate.call(cases, labels: labels),
                           triage: Captain::Evals::RoutingBenchmark::Triage.records(cases, labels: labels))

    text = described_class.new(decided).markdown

    expect(text).to include('- Triage: test_bug', 'After triage (test bugs and judge errors removed)')
  end
end
