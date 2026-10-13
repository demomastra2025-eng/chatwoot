# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::Summary do
  # A scored turn as the runner stores it (string keys, as after a JSON round trip).
  def turn(dialogue, number, fails: [], run: 1, expectation: { 'agent' => 'Запись к врачу' }, fixture: '/set/ws_mid__council_two_part_01.yml')
    { 'fixture' => fixture, 'dialogue' => dialogue, 'run' => run, 'turn' => number, 'reasons' => fails, 'expectation' => expectation,
      'status' => fails.empty? ? 'pass' : 'fail' }
  end

  def summary(*cases) = described_class.call(cases)

  describe 'the dialogues' do
    let(:cases) do
      [turn('council_two_part_01', 1), turn('council_two_part_01', 2),
       turn('council_two_part_02', 1), turn('council_two_part_02', 2, fails: ['wrong_agent']),
       turn('route_single_01', 1, fails: ['wrong_language'])]
    end

    it 'counts the dialogues that passed on every turn, and the failed ones, with the turns of each' do
      result = summary(*cases)

      expect(result[:dialogues]).to include(total: 3, passed: 1, failed: 2, blocked_turns: 0)
      expect(result[:dialogue_summaries]).to contain_exactly(
        a_hash_including(dialogue: 'council_two_part_01', category: 'council_two_part', pass: true, statuses: %w[pass pass], turn_numbers: [1, 2]),
        a_hash_including(dialogue: 'council_two_part_02', pass: false, statuses: %w[pass fail], first_failure: { turn: 2, checks: ['wrong_agent'] }),
        a_hash_including(dialogue: 'route_single_01', category: 'route_single', pass: false, failed: 1)
      )
    end

    it 'sums up per category and per failed check, a check once per turn' do
      result = summary(*cases, turn('route_single_02', 1, fails: %w[wrong_language wrong_language:kk wrong_agent]))

      expect(result[:by_category]).to eq('council_two_part' => { dialogues: 2, dialogues_passed: 1, turns: 4, turns_passed: 3 },
                                         'route_single' => { dialogues: 2, dialogues_passed: 0, turns: 2, turns_passed: 0 })
      expect(result[:by_reason]).to eq('wrong_agent' => 2, 'wrong_language' => 2)
    end
  end

  describe 'a turn after a failed prerequisite' do
    it 'is blocked when it failed itself: its failure is the cascade of the first, not a finding of its own' do
      result = summary(turn('d_01', 1, fails: ['missing_operation:appointment']), turn('d_01', 2, fails: ['wrong_agent']), turn('d_01', 3),
                       turn('d_01', 4, fails: ['wrong_language']))

      expect(result[:dialogue_summaries].first).to include(statuses: %w[fail blocked pass blocked], failed: 1, blocked: 2, pass: false)
      expect(result[:dialogues][:blocked_turns]).to eq(2)
    end

    it 'does not block after a failure that the later turns do not build on, a language or a leak' do
      result = summary(turn('d_01', 1, fails: ['wrong_language']), turn('d_01', 2, fails: ['reply_leak:latin']), turn('d_01', 3, fails: ['wrong_agent']))

      expect(result[:dialogue_summaries].first[:statuses]).to eq(%w[fail fail fail])
    end

    it 'blocks after an aborted run and after a mutation that was not allowed' do
      aborted = summary(turn('d_01', 1, fails: ['technical_handoff']), turn('d_01', 2, fails: ['missing_tool:create_appointment']))
      forbidden = summary(turn('d_02', 1, fails: ['forbidden_tool:create_appointment']), turn('d_02', 2, fails: ['wrong_agent']))

      expect(aborted[:dialogue_summaries].first[:statuses]).to eq(%w[fail blocked])
      expect(forbidden[:dialogue_summaries].first[:statuses]).to eq(%w[fail blocked])
    end

    it 'keeps the turns of one dialogue and run apart from another run of it' do
      result = summary(turn('d_01', 1, fails: ['wrong_agent']), turn('d_01', 2, run: 2, fails: ['wrong_language']))

      expect(result[:dialogue_summaries].pluck(:statuses)).to eq([%w[fail], %w[fail]])
    end

    it 'is blocked when the runner marked it (played on a conversation that staff owned), if it failed; a turn that passed stays a pass' do
      owned = { 'blocked' => true }
      result = summary(turn('d_01', 1), turn('d_01', 2, fails: ['wrong_language']).merge(owned), turn('d_01', 3).merge(owned),
                       turn('d_01', 4, fails: ['wrong_language']))

      expect(result[:dialogue_summaries].first).to include(statuses: %w[pass blocked pass fail], failed: 1, blocked: 1)
    end
  end

  describe 'a judge without a verdict' do
    it 'is no failure of the turn, and the turns that carry it are counted apart, as a warning of today or as a failure of an older run' do
      result = summary(turn('d_01', 1).merge('warnings' => ['judge_unavailable']), turn('d_01', 2, fails: ['judge_invalid_json']),
                       turn('d_02', 1).merge('warnings' => %w[judge_invalid_json handoff_marker_without_tool]), turn('d_02', 2, fails: ['wrong_agent']))

      expect(result[:judge_unusable]).to eq(turns: 3, by_check: { 'judge_invalid_json' => 2, 'judge_unavailable' => 1 })
      expect(result[:by_reason]).to eq('wrong_agent' => 1)
      expect(result[:dialogue_summaries].pluck(:statuses)).to eq([%w[pass pass], %w[pass fail]])
    end

    it 'is nothing to report when no judge failed' do
      expect(summary(turn('d_01', 1))[:judge_unusable]).to eq(turns: 0, by_check: {})
    end
  end

  describe 'pass^k across the runs' do
    it 'counts the dialogues that passed in every run, not the ones that passed once' do
      cases = [turn('a_01', 1, run: 1), turn('a_01', 1, run: 2), turn('a_01', 1, run: 3),
               turn('b_01', 1, run: 1), turn('b_01', 1, run: 2, fails: ['wrong_agent']), turn('b_01', 1, run: 3)]

      result = summary(*cases)

      expect(result[:dialogues][:pass_k]).to eq(k: 3, dialogues: 2, passed_every_run: 1, rate: 0.5)
      expect(result[:dialogues][:per_run]).to eq(1 => { dialogues: 2, passed: 2 }, 2 => { dialogues: 2, passed: 1 }, 3 => { dialogues: 2, passed: 2 })
    end

    it 'does not count a dialogue that a cut-short run reached in fewer runs than the others' do
      cases = [turn('a_01', 1, run: 1), turn('a_01', 1, run: 2), turn('b_01', 1, run: 1)]

      expect(summary(*cases)[:dialogues][:pass_k]).to include(k: 2, dialogues: 2, passed_every_run: 1)
    end
  end

  describe 'the infrastructure bucket' do
    let(:cases) do
      [turn('d_01', 1), turn('d_01', 2, fails: ['provider_error']), turn('d_01', 3, fails: %w[technical_handoff wrong_agent]),
       turn('d_02', 1, fails: ['wrong_agent']), turn('d_02', 2, fails: ['tool_result_fallback'])]
    end

    it 'counts the turns that failed on the infrastructure by check' do
      expect(summary(*cases)[:infra]).to eq(turns: 3, by_check: { 'provider_error' => 1, 'technical_handoff' => 1, 'tool_result_fallback' => 1 })
    end

    it 'leaves those turns out of every accuracy, so an outage does not read as a routing bug' do
      result = summary(*cases)

      expect(result[:routing_accuracy]).to eq(0.5) # d_01 t1 passes, d_02 t1 fails; the three infrastructure turns are out
    end
  end

  describe 'the accuracies' do
    let(:full) { { 'agent' => 'Запись к врачу', 'transfers' => 1, 'staff_handoff' => true, 'acts' => [{ 'tool' => 'create_appointment', 'agent' => 'Запись к врачу' }] } }

    it 'are the share of the turns that state the expectation and ran to their end, per kind of expectation' do
      cases = [turn('a_01', 1, expectation: full), turn('a_01', 2, expectation: full, fails: ['wrong_transfers:0']),
               turn('a_02', 1, expectation: full, fails: %w[staff_handoff_missing missing_act:create_appointment@Запись\ к\ врачу]),
               turn('a_02', 2, expectation: { 'agent' => 'Запись к врачу', 'staff_handoff' => false }, fails: ['staff_handoff_unexpected']),
               turn('a_02', 3, expectation: { 'agent' => 'Запись к врачу', 'staff_handoff' => 'any' }, fails: ['wrong_agent'])]

      result = summary(*cases)

      expect(result).to include(routing_accuracy: 0.8, transfer_accuracy: 0.6667, staff_handoff_accuracy: 0.5, acts_accuracy: 0.6667)
    end

    it 'are nil for an expectation no turn states' do
      result = summary(turn('a_01', 1, expectation: { 'agent' => 'Запись к врачу' }))

      expect(result).to include(routing_accuracy: 1.0, transfer_accuracy: nil, staff_handoff_accuracy: nil, acts_accuracy: nil)
    end

    it 'read an older output that stores no expectation: its turns count for routing' do
      old = { 'fixture' => 'a.yml', 'dialogue' => 'old_01', 'turn' => 1, 'reasons' => ['wrong_agent'], 'status' => 'fail' }

      expect(summary(old)[:routing_accuracy]).to eq(0.0)
    end
  end

  it 'reads the cases of a run that was loaded from JSON, and an empty run' do
    loaded = JSON.parse(JSON.generate([turn('a_01', 1)]))

    expect(summary(*loaded)[:dialogues]).to include(total: 1, passed: 1)
    expect(summary).to include(dialogues: include(total: 0, passed: 0), by_category: {}, by_reason: {}, routing_accuracy: nil)
  end
end
