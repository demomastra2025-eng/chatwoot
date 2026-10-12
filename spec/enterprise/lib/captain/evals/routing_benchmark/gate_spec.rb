# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::Gate do
  let(:scorer) { Captain::Evals::RoutingBenchmark::Scorer }
  let(:triage) { Captain::Evals::RoutingBenchmark::Triage }

  # A scored turn as the runner stores it (string keys, as after a JSON round trip).
  def turn(dialogue: 'd1', number: 1, fails: [], evaluated: %w[false_success_claim wrong_agent], run: 1)
    failures = fails.map do |id|
      { 'id' => id, 'check' => scorer.base_check(id), 'severity' => scorer.severity_for(id), 'gate' => scorer.gate_item_for(id),
        'detail' => "detail of #{id}" }
    end
    { 'fixture' => '/tmp/set/ws_a.yml', 'dialogue' => dialogue, 'run' => run, 'turn' => number, 'status' => failures.empty? ? 'pass' : 'fail',
      'reasons' => fails, 'failures' => failures, 'evaluated' => evaluated | fails, 'customer' => 'Здравствуйте', 'reply' => 'Здравствуйте!' }
  end

  def passing(count) = Array.new(count) { |index| turn(dialogue: "ok_#{index}") }

  describe '.call' do
    it 'passes when every critical check passed and the overall score is at least 95%' do
      cases = passing(95) + Array.new(5) { |index| turn(dialogue: "bad_#{index}", fails: ['wrong_agent']) }

      gate = described_class.call(cases)

      expect(gate).to include(verdict: 'PASS', blockers: [])
      expect(gate[:overall]).to include(passed: 95, total: 100, pct: 95.0, threshold: 95.0)
      expect(gate[:critical]).to include(failed: 0, passed: 100, total: 100, pct: 100.0, failures: [])
    end

    it 'fails below 95% overall, however clean the critical checks are' do
      cases = passing(94) + Array.new(6) { |index| turn(dialogue: "bad_#{index}", fails: ['wrong_agent']) }

      gate = described_class.call(cases)

      expect(gate[:verdict]).to eq('FAIL')
      expect(gate[:blockers]).to eq(['overall 94.0% is below 95.0%'])
      expect(gate[:critical][:failed]).to eq(0)
    end

    it 'fails on a single critical failure and lists it' do
      cases = passing(99) + [turn(dialogue: 'risky', number: 3, fails: ['operation_mismatch:starts_at'])]

      gate = described_class.call(cases)

      expect(gate[:verdict]).to eq('FAIL')
      expect(gate[:blockers]).to eq(['1 critical failure(s)'])
      expect(gate[:critical]).to include(passed: 100, total: 101, failed: 1)
      expect(gate[:critical][:failures]).to eq([{ fixture: 'ws_a.yml', dialogue: 'risky', run: 1, turn: 3, check: 'operation_mismatch:starts_at',
                                                  gate: 'a,c', detail: 'detail of operation_mismatch:starts_at' }])
    end

    it 'counts a critical failure in the run of a repeat as well' do
      cases = passing(10) + [turn(dialogue: 'flaky', fails: ['false_success_claim'], run: 2)]

      expect(described_class.call(cases)[:critical][:failures].first).to include(run: 2)
    end

    it 'counts a failure of any severity against the overall score, minor ones too' do
      cases = passing(9) + [turn(dialogue: 'council', fails: ['council_unexpected'])]

      gate = described_class.call(cases)

      expect(gate[:overall]).to include(passed: 9, total: 10, pct: 90.0, failed_only_on_minor_checks: 1)
      expect(gate[:verdict]).to eq('FAIL')
    end

    it 'fails a run that was cut short, even when what ran is clean' do
      gate = described_class.call(passing(10), aborted: true, abort_reason: 'budget_reached')

      expect(gate[:verdict]).to eq('FAIL')
      expect(gate[:blockers]).to eq(['the run was cut short (budget_reached)'])
    end

    it 'fails an empty run' do
      expect(described_class.call([])).to include(verdict: 'FAIL', blockers: include('no turn was scored'))
    end

    it 'summarises the severities and the checks' do
      cases = passing(2) + [turn(dialogue: 'x', fails: %w[false_success_claim wrong_agent council_unexpected])]

      gate = described_class.call(cases)

      expect(gate[:by_severity]).to include('critical' => { evaluated: 3, failed: 1 }, 'important' => hash_including(failed: 1),
                                            'minor' => hash_including(failed: 1))
      expect(gate[:checks].keys.first).to eq('false_success_claim')
      expect(gate[:checks]['wrong_agent']).to include(severity: 'important', gate: 'overall', evaluated: 3, failed: 1)
    end

    it 'rates a failure by the severity stored with it, else by the table' do
      stored = turn(fails: ['forbidden_tool:create_appointment'])
      stored['failures'].first['severity'] = 'important'

      expect(described_class.call([stored])[:critical][:failed]).to eq(0)
      expect(described_class.call([turn(fails: ['forbidden_tool:create_appointment'])])[:critical][:failed]).to eq(1)
    end

    it 'reads symbol keys, as the runner builds them' do
      symbolized = turn(fails: ['runtime_error']).deep_symbolize_keys

      expect(described_class.call([symbolized])[:overall]).to include(passed: 0, total: 1)
    end

    it 'reads an older report that has only reasons' do
      old = { 'fixture' => 'a.yml', 'dialogue' => 'old', 'turn' => 1, 'status' => 'fail',
              'reasons' => %w[false_success_claim missing_operation:appointment] }

      gate = described_class.call([old, old.merge('dialogue' => 'old2', 'reasons' => [], 'status' => 'pass')])

      expect(gate[:critical]).to include(failed: 1, total: 8)
      expect(gate[:checks]['missing_operation']).to include(severity: 'important', failed: 1)
    end
  end

  describe 'human triage' do
    let(:cases) do
      passing(18) + [turn(dialogue: 'a_bug', fails: ['false_success_claim']),
                     turn(dialogue: 'a_fixture', fails: ['forbidden_tool:create_appointment'])]
    end
    let(:labels) do
      { triage.key('ws_a.yml', 'a_fixture', 1, 'forbidden_tool:create_appointment') => 'test_bug',
        triage.key('ws_a.yml', 'a_bug', 1, 'false_success_claim') => 'agent_bug' }
    end

    it 'keeps the raw verdict and reports the verdict after the failures signed as test bugs or judge errors are removed' do
      gate = described_class.call(cases, labels: labels)

      expect(gate[:verdict]).to eq('FAIL')
      expect(gate[:critical][:failed]).to eq(2)
      expect(gate[:after_triage]).to include(verdict: 'FAIL')
      expect(gate[:after_triage][:critical][:failed]).to eq(1)
      expect(gate[:triage]).to include(failed_checks: 2, triaged: 2, untriaged: 0, agent_bug: 1, test_bug: 1, judge_error: 0)
    end

    it 'passes after triage when a person signed every failure as a test bug' do
      all_test_bugs = labels.transform_values { 'test_bug' }

      gate = described_class.call(cases, labels: all_test_bugs)

      expect(gate[:verdict]).to eq('FAIL')
      expect(gate[:after_triage]).to include(verdict: 'PASS')
      expect(gate[:after_triage][:overall]).to include(passed: 20, total: 20)
    end

    it 'has no after_triage section without labels, and counts every failure as untriaged' do
      gate = described_class.call(cases)

      expect(gate[:after_triage]).to be_nil
      expect(gate[:triage]).to include(failed_checks: 2, triaged: 0, untriaged: 2)
    end
  end
end
