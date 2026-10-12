# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::Compare do
  let(:scorer) { Captain::Evals::RoutingBenchmark::Scorer }

  def turn(dialogue, number = 1, fails: [], fixture: '/a/set1/ws_a.yml', evaluated: %w[false_success_claim wrong_agent runtime_error council_unexpected])
    failures = fails.map do |id|
      { 'id' => id, 'check' => scorer.base_check(id), 'severity' => scorer.severity_for(id), 'gate' => scorer.gate_item_for(id) }
    end
    { 'fixture' => fixture, 'dialogue' => dialogue, 'run' => 1, 'turn' => number, 'status' => failures.empty? ? 'pass' : 'fail',
      'reasons' => fails, 'failures' => failures, 'evaluated' => evaluated | fails, 'customer' => 'x', 'reply' => 'y', 'patient_text' => 'y' }
  end

  def run_of(cases, **extra) = { 'cases' => cases, 'aborted' => false }.merge(extra.stringify_keys)

  # 100 turns, the first ones failing the given checks. The first turn puts gate items a and f to the test.
  def hundred(failing = {})
    Array.new(100) do |index|
      item = turn("d#{index}", fails: failing.fetch(index, []))
      next item unless index.zero?

      item.merge('expectation' => { 'operations' => [{ 'model' => 'appointment', 'kind' => 'create', 'resource' => 'doctor_a', 'service' => 'consult',
                                                       'starts_at' => '2026-10-15T12:00:00+05:00' }] },
                 'human_request' => { 'value' => true, 'source' => 'fixture' })
    end
  end

  # The report of a run together with the decisions of a person: every failed check is an agent bug.
  def signed(cases)
    run_of(cases, triage: Captain::Evals::RoutingBenchmark::Triage.records(cases).map { |record| record.merge('triage' => 'agent_bug') })
  end

  describe '#result' do
    it 'calls two runs with the same results similar, and passes gate item 3 when both pass the gate' do
      cases = hundred(1 => ['wrong_agent'])

      result = described_class.call(signed(cases), signed(hundred(1 => ['wrong_agent'])))

      expect(result).to include(similar: true, not_similar_because: [], both_pass_the_gate: true, gate_item_3: true)
      expect(result[:flipped]).to be_empty
      expect(result[:overall]).to include(delta_points: 0.0)
    end

    it 'does not pass gate item 3 for two similar runs that both fail the gate, or that wait for triage' do
      same_failure = described_class.call(run_of(hundred(7 => ['false_success_claim'])), run_of(hundred(7 => ['false_success_claim'])))
      untriaged = described_class.call(run_of(hundred(1 => ['wrong_agent'])), run_of(hundred(1 => ['wrong_agent'])))

      expect(same_failure).to include(similar: true, both_pass_the_gate: false, gate_item_3: false)
      expect(untriaged).to include(similar: true, both_pass_the_gate: false, gate_item_3: false)
      expect(described_class.new(run_of(hundred), run_of(hundred)).markdown).to include('- Gate item 3 (two consecutive runs, similar and both passing): PASS')
      expect(described_class.new(run_of(hundred(7 => ['false_success_claim'])), run_of(hundred(7 => ['false_success_claim']))).markdown)
        .to include('- Gate item 3 (two consecutive runs, similar and both passing): FAIL')
    end

    it 'compares a check only on the turns that both runs scored and put the check to' do
      older = hundred.map { |item| item.merge('evaluated' => %w[false_success_claim wrong_agent]) }
      newer = hundred(5 => %w[reply_leak:latin reply_leak:identifier])

      result = described_class.call(run_of(older), run_of(newer))

      expect(result).to include(similar: true)
      expect(result[:critical][:new_in_second]).to be_empty
      expect(result[:flipped]).to be_empty
    end

    it 'does not blame a run for the turns the other run never reached' do
      aborted = run_of(hundred.first(50), aborted: true)

      beyond = described_class.call(aborted, run_of(hundred(70 => ['false_success_claim'])))
      within = described_class.call(aborted, run_of(hundred(10 => ['false_success_claim'])))

      expect(beyond).to include(similar: true)
      expect(beyond[:critical][:new_in_second]).to be_empty
      expect(within[:critical][:new_in_second]).to eq(['ws_a.yml/d10/run1/t1 false_success_claim'])
      expect(described_class.call(run_of(hundred(70 => ['false_success_claim'])), aborted)[:critical][:fixed_in_second]).to be_empty
    end

    it 'is similar within 2 points and not beyond' do
      first = run_of(hundred(1 => ['wrong_agent'], 2 => ['wrong_agent'], 3 => ['wrong_agent']))
      within = run_of(hundred(1 => ['wrong_agent'])) # 97 against 99: 2 points
      beyond = run_of(hundred) # 97 against 100: 3 points

      expect(described_class.call(first, within)).to include(similar: true)
      expect(described_class.call(first, beyond)).to include(similar: false, not_similar_because: ['overall scores differ by 3.0 points (limit 2.0)'])
    end

    it 'is not similar when the second run has a critical failure the first did not' do
      result = described_class.call(run_of(hundred), run_of(hundred(7 => ['false_success_claim'])))

      expect(result[:similar]).to be(false)
      expect(result[:not_similar_because]).to eq(['1 critical failure(s) appear only in the second run'])
      expect(result[:critical][:new_in_second]).to eq(['ws_a.yml/d7/run1/t1 false_success_claim'])
      expect(result[:both_pass_the_gate]).to be(false)
    end

    it 'does not call a critical failure that both runs share new, and reports one that is gone' do
      shared = described_class.call(run_of(hundred(7 => ['false_success_claim'])), run_of(hundred(7 => ['false_success_claim'])))
      gone = described_class.call(run_of(hundred(7 => ['false_success_claim'])), run_of(hundred))

      expect(shared).to include(similar: true)
      expect(shared[:critical][:new_in_second]).to be_empty
      expect(gone[:critical][:fixed_in_second]).to eq(['ws_a.yml/d7/run1/t1 false_success_claim'])
    end

    it 'lists the checks that flipped between the runs' do
      first = run_of(hundred(1 => ['wrong_agent'], 2 => ['runtime_error']))
      second = run_of(hundred(1 => ['wrong_agent'], 3 => ['runtime_error']))

      result = described_class.call(first, second)

      expect(result[:flipped]).to eq([
                                       { turn: 'ws_a.yml/d2/run1/t1', check: 'runtime_error', severity: 'important', first: 'fail', second: 'pass' },
                                       { turn: 'ws_a.yml/d3/run1/t1', check: 'runtime_error', severity: 'important', first: 'pass', second: 'fail' }
                                     ])
    end

    it 'compares the failed turns of every check' do
      first = run_of(hundred(1 => ['wrong_agent'], 2 => ['wrong_agent'], 3 => ['council_unexpected']))
      second = run_of(hundred(1 => ['wrong_agent']))

      result = described_class.call(first, second)

      expect(result[:checks]).to eq([
                                      { check: 'wrong_agent', severity: 'important', first: 2, second: 1, delta: -1 },
                                      { check: 'council_unexpected', severity: 'minor', first: 1, second: 0, delta: -1 }
                                    ])
    end

    it 'compares only the turns both runs scored when matching flips' do
      first = run_of(hundred(1 => ['wrong_agent']).first(50))
      second = run_of(hundred.last(60))

      expect(described_class.call(first, second)[:turns_compared]).to eq(10)
      expect(described_class.call(first, second)[:flipped].pluck(:turn)).to be_empty
    end

    it 'keeps the runs of a repeated fixture apart' do
      repeated = hundred.first(2).map { |item| item.merge('run' => 2) }

      result = described_class.call(run_of(hundred.first(2) + repeated), run_of(hundred.first(2) + repeated))

      expect(result[:turns_compared]).to eq(4)
    end

    it 'matches fixtures by file name, not by directory' do
      first = run_of([turn('d', fails: ['runtime_error'], fixture: '/set1/ws_a.yml')])
      second = run_of([turn('d', fails: ['runtime_error'], fixture: '/set2/ws_a.yml')])

      expect(described_class.call(first, second)[:flipped]).to be_empty
    end

    it 'compares reports of the first harness version, which carry only reasons' do
      old = lambda do |reasons|
        run_of([{ 'fixture' => 'a.yml', 'dialogue' => 'd', 'turn' => 1, 'status' => reasons.empty? ? 'pass' : 'fail', 'reasons' => reasons }])
      end

      result = described_class.call(old.call(['false_success_claim']), old.call([]))

      expect(result[:critical][:fixed_in_second]).to eq(['a.yml/d/run1/t1 false_success_claim'])
    end
  end

  describe '#markdown' do
    it 'prints the verdict, the differences and the flipped checks' do
      first = run_of(hundred(1 => ['wrong_agent'], 2 => ['runtime_error']))
      second = run_of(hundred(1 => ['wrong_agent'], 7 => ['false_success_claim']))

      text = described_class.new(first, second).markdown

      expect(text).to start_with("# Benchmark comparison\n\n**Similar: no**")
      expect(text).to include('- First: 98/100 turns (98.0%)', '- Second: 98/100 turns (98.0%)', '- New in the second run: ws_a.yml/d7/run1/t1 false_success_claim',
                              '| `wrong_agent` | important | 1 | 1 | +0 |', '## Flipped checks', '- ws_a.yml/d2/run1/t1 `runtime_error` (important): first fail, second pass')
    end
  end
end
