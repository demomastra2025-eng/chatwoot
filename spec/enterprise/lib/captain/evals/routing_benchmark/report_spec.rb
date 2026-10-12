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
      'expectation' => { 'agent' => 'Запись к врачу', 'must_not_call' => ['create_appointment'] } }
  end
  let(:fine) do
    { 'fixture' => '/x/ws_mid__kazakh_mixed_01.yml', 'dialogue' => 'kazakh_mixed_01', 'run' => 1, 'turn' => 1, 'status' => 'pass', 'reasons' => [],
      'failures' => [], 'evaluated' => %w[wrong_agent false_success_claim], 'customer' => 'Сәлеметсіз бе', 'reply' => 'Сәлеметсіз бе!' }
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
