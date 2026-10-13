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
      'reasons' => fails, 'failures' => failures, 'evaluated' => evaluated | fails, 'customer' => 'Здравствуйте', 'reply' => 'Здравствуйте!',
      'patient_text' => 'Здравствуйте!' }
  end

  def operation(extra = {})
    { 'model' => 'appointment', 'kind' => 'create', 'resource' => 'doctor_a', 'service' => 'consult',
      'starts_at' => '2026-10-15T12:00:00+05:00' }.merge(extra)
  end

  # The v2 form: the start is pinned among the params and nothing else is.
  def v2_operation(extra = {})
    { 'model' => 'appointment', 'kind' => 'create', 'params' => { 'status' => 'scheduled', 'starts_at' => '2026-10-15T12:00:00+05:00' } }.merge(extra)
  end

  # A turn whose fixture pins the start time of the booking it expects (gate item a), and one in which the customer asks for a
  # person (gate item f).
  def booking_turn(dialogue = 'booking', operations: [operation], **options)
    turn(dialogue: dialogue, **options).merge('expectation' => { 'operations' => operations })
  end

  def person_turn(dialogue = 'person', **options)
    turn(dialogue: dialogue, **options).merge('human_request' => { 'value' => true, 'source' => 'fixture' })
  end

  # `count` clean turns; the first two put gate items a and f to the test.
  def passing(count)
    Array.new(count) do |index|
      case index
      when 0 then booking_turn
      when 1 then person_turn
      else turn(dialogue: "ok_#{index}")
      end
    end
  end

  def bad_turns(count, check = 'wrong_agent') = Array.new(count) { |index| turn(dialogue: "bad_#{index}", fails: [check]) }

  # The decisions of a person: every failed check of the given turns is signed with the label.
  def signed_off(cases, label = 'agent_bug')
    cases.flat_map { |item| item['failures'].map { |failure| [triage.key(item['fixture'], item['dialogue'], item['turn'], failure['id']), label] } }.to_h
  end

  describe '.call' do
    it 'passes when every critical check passed, the overall score is at least 95% and every failed check is triaged' do
      bad = bad_turns(5)
      cases = passing(95) + bad

      gate = described_class.call(cases, labels: signed_off(bad))

      expect(gate).to include(verdict: 'PASS', blockers: [])
      expect(gate[:overall]).to include(passed: 95, total: 100, pct: 95.0, threshold: 95.0)
      expect(gate[:critical]).to include(failed: 0, passed: 100, total: 100, pct: 100.0, failures: [])
    end

    it 'is not a pass while a failed check waits for the triage of a person: 96% with untriaged failures is PENDING_TRIAGE' do
      gate = described_class.call(passing(96) + bad_turns(4))

      expect(gate).to include(verdict: 'PENDING_TRIAGE', blockers: ['4 failed check(s) not triaged by a person'])
      expect(gate[:triage]).to include(failed_checks: 4, triaged: 0, untriaged: 4)
      expect(gate[:overall][:pct]).to eq(96.0)
    end

    it 'turns PENDING_TRIAGE into PASS once a person signed every failed check, with any of the three labels' do
      bad = bad_turns(3) + [turn(dialogue: 'minor', fails: ['council_unexpected'])]
      labels = signed_off(bad).keys.zip(triage::LABELS.cycle).to_h

      expect(described_class.call(passing(96) + bad).fetch(:verdict)).to eq('PENDING_TRIAGE')
      expect(described_class.call(passing(96) + bad, labels: labels)).to include(verdict: 'PASS', blockers: [])
    end

    it 'keeps FAIL for a hard blocker, and lists the untriaged failures next to it' do
      gate = described_class.call(passing(10) + bad_turns(2))

      expect(gate[:verdict]).to eq('FAIL')
      expect(gate[:blockers]).to eq(['overall 83.33% is below 95.0%', '2 failed check(s) not triaged by a person'])
    end

    it 'fails below 95% overall, however clean the critical checks are' do
      bad = bad_turns(6)
      cases = passing(94) + bad

      gate = described_class.call(cases, labels: signed_off(bad))

      expect(gate[:verdict]).to eq('FAIL')
      expect(gate[:blockers]).to eq(['overall 94.0% is below 95.0%'])
      expect(gate[:critical][:failed]).to eq(0)
    end

    it 'fails on a single critical failure and lists it' do
      risky = turn(dialogue: 'risky', number: 3, fails: ['operation_mismatch:starts_at'])
      cases = passing(99) + [risky]

      gate = described_class.call(cases, labels: signed_off([risky]))

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

    it 'counts one critical check once on a turn: the plain check and its failed form are not both counted' do
      leaky = turn(dialogue: 'leaky', fails: %w[reply_leak:identifier reply_leak:latin], evaluated: %w[reply_leak wrong_agent])
      cases = passing(2) + [leaky]

      gate = described_class.call(cases, labels: signed_off([leaky]))

      # false_success_claim on the two clean turns; on the leaky one only reply_leak, in its two failed forms
      expect(gate[:critical]).to include(total: 2 + 2, failed: 2, passed: 2)
      expect(gate[:by_severity]['critical']).to eq(evaluated: 4, failed: 2)
      expect(gate[:checks]['reply_leak']).to include(evaluated: 1, failed: 1)
    end

    it 'reads an older report that has only reasons' do
      old = { 'fixture' => 'a.yml', 'dialogue' => 'old', 'turn' => 1, 'status' => 'fail',
              'reasons' => %w[false_success_claim missing_operation:appointment] }

      gate = described_class.call([old, old.merge('dialogue' => 'old2', 'reasons' => [], 'status' => 'pass')])

      expect(gate[:critical]).to include(failed: 1, total: 8)
      expect(gate[:checks]['missing_operation']).to include(severity: 'important', failed: 1)
    end
  end

  describe 'coverage of gate items a and f' do
    it 'counts the expectations that pin the start time, and the turns that ask for a person' do
      cases = passing(10) + [booking_turn('cancelled', operations: [operation('kind' => 'cancel', 'service' => nil, 'patient' => nil)])]

      gate = described_class.call(cases)

      expect(gate[:verdict]).to eq('PASS')
      expect(gate[:coverage]).to include('a' => { covered: 2, expected: 2 }, 'f' => { covered: 1 }, 'c' => { covered: 0 }, 'd' => { covered: 11 })
    end

    it 'takes the start time of the v2 schema among the params as the pin: the doctor is any that fits, so the fixture names none' do
      gate = described_class.call(passing(10) + [booking_turn('v2', operations: [v2_operation, v2_operation('kind' => 'update')])])

      expect(gate[:verdict]).to eq('PASS')
      expect(gate[:coverage]['a']).to eq(covered: 3, expected: 3)
    end

    it 'blocks the gate when a clean run holds no expectation with a start time: a booking at the wrong time could not be noticed' do
      old_form = { 'model' => 'appointment', 'kind' => 'create', 'params' => { 'status' => 'scheduled' } }
      cases = [turn(dialogue: 'old_form').merge('expectation' => { 'operations' => [old_form] }), person_turn] +
              Array.new(18) { |index| turn(dialogue: "d#{index}") }

      gate = described_class.call(cases)

      expect(gate[:verdict]).to eq('FAIL')
      expect(gate[:blockers]).to eq(['item a not covered: 1 of 1 expected operations pin no start time (params.starts_at)'])
      expect(gate[:critical][:failed]).to eq(0)
    end

    it 'names how many of the expected operations pin no start time' do
      vague = [operation('starts_at' => nil), v2_operation('params' => { 'status' => 'scheduled' }), operation('resource' => nil), v2_operation]

      gate = described_class.call(passing(10) + [booking_turn('vague', operations: vague)])

      expect(gate[:blockers]).to eq(['item a not covered: 2 of 5 expected operations pin no start time (params.starts_at)'])
      expect(gate[:coverage]['a']).to eq(covered: 3, expected: 5)
    end

    it 'does not count count: 0 ("no such row") or an operation on a deal' do
      cases = passing(10) + [booking_turn('none', operations: [operation('count' => 0), { 'model' => 'deal', 'kind' => 'create' }])]

      expect(described_class.call(cases)).to include(verdict: 'PASS')
      expect(described_class.call(cases)[:coverage]['a']).to eq(covered: 1, expected: 1)
    end

    it 'reads the old form of a cancellation as a cancellation, which needs no service or patient' do
      old = { 'model' => 'appointment', 'kind' => 'update', 'resource' => 'doctor_a', 'starts_at' => '2026-10-15T12:00:00+05:00',
              'params' => { 'status' => 'cancelled' } }

      expect(described_class.call(passing(10) + [booking_turn('old', operations: [old])])).to include(verdict: 'PASS')
    end

    it 'blocks the gate when no turn asks for a person: a missing handoff could not be noticed' do
      cases = passing(10).reject { |item| item['human_request'] }

      gate = described_class.call(cases)

      expect(gate).to include(verdict: 'FAIL', blockers: ['item f not covered: no turn asks for a person'])
    end

    it 'blocks a run of the first harness version, which carries no expectations: it can prove nothing' do
      old = { 'fixture' => 'a.yml', 'dialogue' => 'old', 'turn' => 1, 'status' => 'pass', 'reasons' => [] }

      gate = described_class.call([old])

      expect(gate[:verdict]).to eq('FAIL')
      expect(gate[:blockers]).to include(a_string_starting_with('item a not covered'), 'item f not covered: no turn asks for a person')
    end

    it 'counts the replies with a claim for item b and the changed appointments for item c' do
      claiming = booking_turn('claim').merge('evidence' => { 'claimed_operations' => ['book'] }, 'db_delta' => [{ 'change' => 'created' }])

      expect(described_class.call(passing(3) + [claiming])[:coverage]).to include('b' => { covered: 1 }, 'c' => { covered: 1 })
    end
  end

  describe 'the checks of the v2 schema' do
    it 'rates the new checks: the critical ones block the release at once, the others count against the overall score' do
      critical = %w[succeeded_forbidden:create_appointment false_handoff_claim tool_result_fallback staff_handoff_missing:person_request
                    reply_leak:stock_text reply_leak:agent_name operation_mismatch:starts_at duplicate_operation]
      important = %w[missing_act:create_appointment@Запись\ к\ врачу wrong_transfers:1 staff_handoff_missing staff_handoff_unexpected
                     missing_done_statement:create_appointment council_changed_hands technical_handoff provider_error wrong_language]

      expect(critical.map { |id| scorer.severity_for(id) }.uniq).to eq(['critical'])
      expect(important.map { |id| scorer.severity_for(id) }.uniq).to eq(['important'])
    end

    it 'fails a run on one wrong start time or one false handoff claim, and on a stock sentence in a patient reply' do
      %w[operation_mismatch:starts_at false_handoff_claim reply_leak:stock_text succeeded_forbidden:update_appointment].each do |check|
        gate = described_class.call(passing(40) + [turn(dialogue: 'risky', fails: [check])])

        expect(gate).to include(verdict: 'FAIL', blockers: include('1 critical failure(s)')), check
      end
    end

    it 'reads the old name of the renamed handoff check in an older output' do
      old = turn(dialogue: 'old', fails: ['handoff_claim_unsupported'])
      old['failures'].each { |failure| failure.delete('severity') }

      expect(described_class.call(passing(10) + [old])[:critical]).to include(failed: 1)
    end
  end

  describe 'failures of the infrastructure' do
    let(:infra_cases) do
      passing(97) + [turn(dialogue: 'down_1', fails: ['provider_error']), turn(dialogue: 'down_2', fails: %w[technical_handoff wrong_agent]),
                     turn(dialogue: 'down_3', fails: ['technical_handoff'])]
    end

    it 'counts them apart by check, and still as failed turns that need a triage' do
      gate = described_class.call(infra_cases)

      expect(gate[:infra]).to eq(turns: 3, by_check: { 'provider_error' => 1, 'technical_handoff' => 2 })
      expect(gate[:overall]).to include(passed: 97, total: 100, failed_turns: 3)
      expect(gate).to include(verdict: 'PENDING_TRIAGE', blockers: ['4 failed check(s) not triaged by a person'])
    end

    it 'fails the run when too many turns end in an infrastructure failure: they are never left out of the score' do
      many = passing(90) + Array.new(10) { |index| turn(dialogue: "down_#{index}", fails: ['provider_error']) }

      expect(described_class.call(many, labels: signed_off(many.last(10)))).to include(verdict: 'FAIL', blockers: ['overall 90.0% is below 95.0%'])
    end

    it 'passes once a person triaged every failure and the score holds' do
      expect(described_class.call(infra_cases, labels: signed_off(infra_cases.last(3)))).to include(verdict: 'PASS', blockers: [])
    end
  end

  describe 'the silent handoff' do
    it 'blocks the gate when the handoff notice of the synthetic account is not blank: the text of a handoff is not checked' do
      gate = described_class.call(passing(10), silent_handoff: false)

      expect(gate).to include(verdict: 'FAIL', silent_handoff: false)
      expect(gate[:blockers]).to include(a_string_starting_with('the handoff notice of the synthetic account is not blank'))
    end

    it 'does not block when the notice is blank or was not checked (an older output)' do
      expect(described_class.call(passing(10), silent_handoff: true)).to include(verdict: 'PASS', silent_handoff: true)
      expect(described_class.call(passing(10))).to include(verdict: 'PASS')
      expect(described_class.call(passing(10))).not_to have_key(:silent_handoff)
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
