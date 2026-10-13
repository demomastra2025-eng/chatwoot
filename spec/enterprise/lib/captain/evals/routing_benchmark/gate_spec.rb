# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::Gate do
  let(:scorer) { Captain::Evals::RoutingBenchmark::Scorer }
  let(:triage) { Captain::Evals::RoutingBenchmark::Triage }

  # A scored turn as the runner stores it (string keys, as after a JSON round trip).
  def turn(dialogue: 'd1', number: 1, fails: [], evaluated: %w[duplicate_operation wrong_agent], run: 1)
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

  # The blocker of gate item a for `count` of `total` expected operations that pin no start time (or, for a move, no old start).
  def unpinned_message(count, total)
    "item a not covered: #{count} of #{total} expected operations pin no start time (params.starts_at), or pin no previous_starts_at for a move"
  end

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
      cases = passing(10) + [turn(dialogue: 'flaky', fails: ['duplicate_operation'], run: 2)]

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
      cases = passing(2) + [turn(dialogue: 'x', fails: %w[duplicate_operation wrong_agent council_unexpected])]

      gate = described_class.call(cases)

      expect(gate[:by_severity]).to include('critical' => { evaluated: 3, failed: 1 }, 'important' => hash_including(failed: 1),
                                            'minor' => hash_including(failed: 1))
      expect(gate[:checks].keys.first).to eq('duplicate_operation')
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
      wrong = turn(dialogue: 'wrong', fails: %w[operation_mismatch:starts_at operation_mismatch:resource], evaluated: %w[operation_mismatch wrong_agent])
      cases = passing(2) + [wrong]

      gate = described_class.call(cases, labels: signed_off([wrong]))

      # duplicate_operation on the two clean turns; on the wrong one only operation_mismatch, in its two failed forms
      expect(gate[:critical]).to include(total: 2 + 2, failed: 2, passed: 2)
      expect(gate[:by_severity]['critical']).to eq(evaluated: 4, failed: 2)
      expect(gate[:checks]['operation_mismatch']).to include(evaluated: 1, failed: 1)
    end

    it 'reads an older report that has only reasons' do
      old = { 'fixture' => 'a.yml', 'dialogue' => 'old', 'turn' => 1, 'status' => 'fail',
              'reasons' => %w[duplicate_operation missing_operation:appointment] }

      gate = described_class.call([old, old.merge('dialogue' => 'old2', 'reasons' => [], 'status' => 'pass')])

      expect(gate[:critical]).to include(failed: 1, total: 4)
      expect(gate[:checks]['missing_operation']).to include(severity: 'important', failed: 1)
    end
  end

  # The runner marks a turn it played on a conversation that staff owned and nobody gave back (it cannot happen live). The verdict holds
  # the run to every turn; the score without the marked turns is shown next to it, so the reader sees both.
  describe 'blocked turns' do
    def blocked_turn(index, fails: [])
      turn(dialogue: "owned_#{index}", fails: fails).merge('blocked' => true)
    end

    it 'shows the score of all the turns and the score without the blocked ones, and holds the verdict to all the turns' do
      cases = passing(88) + bad_turns(4) + Array.new(6) { |index| blocked_turn(index, fails: ['wrong_agent']) } + [blocked_turn(7)]

      gate = described_class.call(cases)

      expect(gate[:overall]).to include(passed: 89, total: 99, pct: 89.9, blocked_turns: 7)
      expect(gate[:overall_unblocked]).to include(passed: 88, total: 92, pct: 95.65, threshold: 95.0)
      expect(gate[:overall_unblocked]).not_to have_key(:blocked_turns)
      expect(gate[:verdict]).to eq('FAIL')
      expect(gate[:blockers]).to include('overall 89.9% is below 95.0% (95.65% without the 7 blocked turn(s))')
    end

    it 'says nothing of blocked turns when there are none, and keeps the same blocker text' do
      gate = described_class.call(passing(10) + bad_turns(2))

      expect(gate[:overall]).to include(blocked_turns: 0)
      expect(gate[:overall_unblocked]).to include(passed: 10, total: 12)
      expect(gate[:blockers]).to include('overall 83.33% is below 95.0%')
    end

    it 'computes both scores after the triage as well' do
      owned = Array.new(5) { |index| blocked_turn(index, fails: ['wrong_agent']) }
      cases = passing(95) + owned

      gate = described_class.call(cases, labels: signed_off(owned, 'test_bug'))

      expect(gate[:after_triage]).to include(verdict: 'PASS')
      expect(gate[:after_triage][:overall]).to include(passed: 100, total: 100, blocked_turns: 5)
      expect(gate[:after_triage][:overall_unblocked]).to include(passed: 95, total: 95)
    end
  end

  # The rubric judge is not a check of the agent: a report of an older run holds a judge without a verdict as a failure of the turn, and it
  # is no failure of the agent. It leaves the turn not evaluated (decision 3A), as a report of today does.
  describe 'a judge without a verdict' do
    let(:cases) do
      passing(10).map do |item|
        item.merge('failures' => [{ 'id' => 'judge_unavailable', 'check' => 'judge_unavailable', 'severity' => 'minor', 'gate' => 'none' }],
                   'reasons' => ['judge_unavailable'], 'status' => 'fail')
      end
    end

    it 'fails no turn, needs no triage, and leaves every turn not evaluated: the verdict is INCOMPLETE_EVALUATION' do
      gate = described_class.call(cases)

      expect(gate[:overall]).to include(passed: 0, total: 0, not_evaluated: 10)
      expect(gate[:triage]).to include(failed_checks: 0, untriaged: 0)
      expect(gate[:not_evaluated]).to eq(turns: 10, by_check: { 'judge' => 10 })
      expect(gate[:verdict]).to eq('INCOMPLETE_EVALUATION')
    end

    it 'is read the same way when the report holds it as the warning or as the judge of the turn' do
      warned = passing(10).map { |item| item.merge('warnings' => ['judge_invalid_json']) }
      judged = passing(10).map { |item| item.merge('judge' => { 'unusable' => 'judge_unavailable', 'detail' => 'RubyLLM::Error' }) }

      expect(described_class.call(warned)[:not_evaluated]).to eq(turns: 10, by_check: { 'judge' => 10 })
      expect(described_class.call(judged)).to include(verdict: 'INCOMPLETE_EVALUATION')
    end

    it 'does not hide a failure of a fact check on the same turn' do
      failing = cases.first.merge('reasons' => %w[judge_unavailable wrong_agent],
                                  'failures' => cases.first['failures'] + [{ 'id' => 'wrong_agent', 'check' => 'wrong_agent', 'severity' => 'important', 'gate' => 'overall' }])

      expect(described_class.call([failing] + cases.drop(1))[:overall]).to include(failed_turns: 1, not_evaluated: 9)
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
      move = v2_operation('kind' => 'update', 'previous_starts_at' => '2026-10-13T15:00:00+05:00')
      gate = described_class.call(passing(10) + [booking_turn('v2', operations: [v2_operation, move])])

      expect(gate[:verdict]).to eq('PASS')
      expect(gate[:coverage]['a']).to eq(covered: 3, expected: 3)
    end

    it 'blocks the gate when a clean run holds no expectation with a start time: a booking at the wrong time could not be noticed' do
      old_form = { 'model' => 'appointment', 'kind' => 'create', 'params' => { 'status' => 'scheduled' } }
      cases = [turn(dialogue: 'old_form').merge('expectation' => { 'operations' => [old_form] }), person_turn] +
              Array.new(18) { |index| turn(dialogue: "d#{index}") }

      gate = described_class.call(cases)

      expect(gate[:verdict]).to eq('FAIL')
      expect(gate[:blockers]).to eq([unpinned_message(1, 1)])
      expect(gate[:critical][:failed]).to eq(0)
    end

    it 'names how many of the expected operations pin no start time' do
      vague = [operation('starts_at' => nil), v2_operation('params' => { 'status' => 'scheduled' }), operation('resource' => nil), v2_operation]

      gate = described_class.call(passing(10) + [booking_turn('vague', operations: vague)])

      expect(gate[:blockers]).to eq([unpinned_message(2, 5)])
      expect(gate[:coverage]['a']).to eq(covered: 3, expected: 5)
    end

    it 'does not count a move as pinned before it names the appointment it moves: the wrong one could be moved to the requested time' do
      pinned = v2_operation('kind' => 'update', 'previous_starts_at' => '2026-10-13T15:00:00+05:00')
      bare = v2_operation('kind' => 'update')
      symbolic_bare = operation('kind' => 'update')
      cancel = v2_operation('kind' => 'update', 'params' => { 'status' => 'cancelled', 'starts_at' => '2026-10-15T12:00:00+05:00' })

      gate = described_class.call(passing(10) + [booking_turn('moves', operations: [pinned, bare, symbolic_bare, cancel])])

      expect(gate[:verdict]).to eq('FAIL')
      # the first of the ten clean turns (passing) holds one more pinned booking
      expect(gate[:blockers]).to eq([unpinned_message(2, 5)])
      expect(gate[:coverage]['a']).to eq(covered: 3, expected: 5)
      expect(described_class.specific?(symbolic_bare.merge('previous_starts_at' => '2026-10-13T15:00:00+05:00'))).to be(true)
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

    it 'counts only the turns that the fixture states as a request for a person: the wording detector alone puts nothing of item f to the test' do
      detector = turn(dialogue: 'detector').merge('human_request' => { 'value' => true, 'source' => 'detector' })
      denied = turn(dialogue: 'denied').merge('human_request' => { 'value' => false, 'source' => 'fixture' })
      cases = passing(10).reject { |item| item['human_request'] } + [detector, denied]

      gate = described_class.call(cases)

      expect(gate[:coverage]['f']).to eq(covered: 0)
      expect(gate[:blockers]).to include('item f not covered: no turn asks for a person')
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

    it 'fails a run on one wrong start time, one forbidden success or one missing handoff of a request the fixture states' do
      %w[operation_mismatch:starts_at succeeded_forbidden:update_appointment staff_handoff_missing:person_request human_handoff_missing].each do |check|
        gate = described_class.call(passing(40) + [turn(dialogue: 'risky', fails: [check])])

        expect(gate).to include(verdict: 'FAIL', blockers: include('1 critical failure(s)')), check
      end
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

    it 'blocks the gate when the runner could not read the notice: the text of the handoff turns was skipped on trust, not on proof' do
      gate = described_class.call(passing(10), silent_handoff: nil, silent_handoff_error: 'ActiveRecord::StatementInvalid')

      expect(gate).to include(verdict: 'FAIL', silent_handoff_error: 'ActiveRecord::StatementInvalid')
      expect(gate[:blockers]).to eq(['silent handoff not proven: the notice could not be read (ActiveRecord::StatementInvalid); ' \
                                     'the text of a handoff turn is not checked'])
    end

    it 'blocks a report that holds silent handoff turns and carries no proof that the notice is blank, and passes once it does' do
      cases = passing(10) + [turn(dialogue: 'handed').merge('silent_handoff' => true)]

      gate = described_class.call(cases)

      expect(gate[:verdict]).to eq('FAIL')
      expect(gate[:blockers]).to eq(['silent handoff not proven: the report has silent handoff turns and no proof that the notice is blank; ' \
                                     'the text of a handoff turn is not checked'])
      expect(described_class.call(cases, silent_handoff: true)).to include(verdict: 'PASS', blockers: [])
    end

    it 'does not read an error as a failure when the notice was read after all' do
      expect(described_class.call(passing(10), silent_handoff: true, silent_handoff_error: 'Timeout::Error')).to include(verdict: 'PASS')
    end
  end

  describe 'human triage' do
    let(:cases) do
      passing(18) + [turn(dialogue: 'a_bug', fails: ['duplicate_operation']),
                     turn(dialogue: 'a_fixture', fails: ['forbidden_tool:create_appointment'])]
    end
    let(:labels) do
      { triage.key('ws_a.yml', 'a_fixture', 1, 'forbidden_tool:create_appointment') => 'test_bug',
        triage.key('ws_a.yml', 'a_bug', 1, 'duplicate_operation') => 'agent_bug' }
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

  # Decision 2A: a check that reads text is a hint, never a failure of a turn or of the gate.
  describe 'the hits of the checks that read text' do
    let(:hits) { %w[false_success_claim false_handoff_claim reply_leak:latin reply_leak:stock_text wrong_language foreign_patient_data] }

    it 'fail no turn and no gate: an older output that holds them as failures is read as hints' do
      old = turn(dialogue: 'leaky', fails: hits, evaluated: %w[duplicate_operation wrong_agent] + hits)

      gate = described_class.call(passing(10) + [old])

      expect(gate).to include(verdict: 'PASS', blockers: [])
      expect(gate[:critical]).to include(failed: 0, total: 11, pct: 100.0)
      expect(gate[:overall]).to include(passed: 11, total: 11, failed_turns: 0)
      expect(gate[:triage]).to include(failed_checks: 0, untriaged: 0)
      expect(gate[:checks].keys).to contain_exactly('duplicate_operation', 'wrong_agent')
      expect(gate[:hints]).to include(total: 6, critical: 5)
      expect(gate[:hints][:by_check].keys).to eq(%w[false_handoff_claim false_success_claim foreign_patient_data reply_leak wrong_language].sort_by do |name|
        [triage.severity_rank(scorer.severity_for(name)), name]
      end)
    end

    it 'are counted per run, the critical ones apart, from the hints a turn of today stores' do
      critical = { 'id' => 'false_success_claim', 'check' => 'false_success_claim', 'severity' => 'critical', 'gate' => 'b', 'detail' => 'claims book' }
      important = { 'id' => 'wrong_language', 'check' => 'wrong_language', 'severity' => 'important', 'gate' => 'overall' }
      cases = [turn(dialogue: 'a', run: 1).merge('hints' => [critical, important]), turn(dialogue: 'a', run: 2).merge('hints' => [important]),
               turn(dialogue: 'b', run: 1), booking_turn.merge('run' => 1), person_turn.merge('run' => 1)]

      gate = described_class.call(cases)

      expect(gate[:runs][1]).to include(hints: 2, critical_hints: 1, critical_failures: 0)
      expect(gate[:runs][2]).to include(hints: 1, critical_hints: 0)
      expect(gate[:hints]).to include(total: 3, critical: 1)
      expect(gate[:verdict]).to eq('PASS')
    end

    it 'are not checks put to a turn: an older output that lists them as evaluated does not count them as passed critical checks' do
      old = turn(dialogue: 'old', evaluated: %w[false_success_claim internal_text_leak reply_leak])

      expect(described_class.call([old])[:critical]).to include(total: 0, failed: 0)
    end
  end

  # Decision 3A: a turn whose required judge check has no verdict is not evaluated: not a pass, not a failure.
  describe 'turns that are not evaluated' do
    def left(index, **options) = turn(dialogue: "left_#{index}", **options).merge('status' => 'not_evaluated', 'not_evaluated' => ['judge'])

    it 'make the verdict INCOMPLETE_EVALUATION, however clean the rest is, and stay out of the percentage' do
      gate = described_class.call(passing(20) + [left(1), left(2)])

      expect(gate[:verdict]).to eq('INCOMPLETE_EVALUATION')
      expect(gate[:blockers]).to eq(['2 turn(s) not evaluated: a required check has no verdict (the rubric judge gave none)'])
      expect(gate[:overall]).to include(passed: 20, total: 20, pct: 100.0, not_evaluated: 2)
      expect(gate[:not_evaluated]).to eq(turns: 2, by_check: { 'judge' => 2 })
      expect(gate[:runs][1]).to include(turns: 22, passed: 20, failed: 0, not_evaluated: 2, pct: 100.0)
    end

    it 'do not hide a failure: a critical failure makes the verdict FAIL, with the turns left unevaluated listed next to it' do
      risky = turn(dialogue: 'risky', fails: ['operation_mismatch:starts_at'])

      gate = described_class.call(passing(20) + [left(1), risky])

      expect(gate[:verdict]).to eq('FAIL')
      expect(gate[:blockers]).to include('1 critical failure(s)', a_string_starting_with('1 turn(s) not evaluated'))
    end

    it 'are not the turns that failed a fact check: such a turn is failed, whatever the judge said about it' do
      failed = left(1, fails: ['wrong_agent']).merge('status' => 'fail')

      gate = described_class.call(passing(20) + [failed])

      expect(gate[:overall]).to include(passed: 20, total: 21, failed_turns: 1, not_evaluated: 0)
      expect(gate[:not_evaluated]).to eq(turns: 0, by_check: {})
      expect(gate[:verdict]).to eq('PENDING_TRIAGE')
    end

    it 'are no pass of the percentage, and never a failure of it: a run with nothing evaluated is incomplete, not failed' do
      gate = described_class.call([left(1), left(2)].map { |item| item.merge('human_request' => { 'value' => true }) })

      expect(gate[:overall]).to include(passed: 0, total: 0, not_evaluated: 2)
      expect(gate[:blockers]).not_to include(a_string_starting_with('overall'))
      expect(gate[:verdict]).to eq('FAIL') # items a and f are not covered by these two turns
      expect(gate[:blockers]).to include('2 turn(s) not evaluated: a required check has no verdict (the rubric judge gave none)')
    end

    it 'come before the triage: INCOMPLETE_EVALUATION, not PENDING_TRIAGE, while a verdict is missing' do
      gate = described_class.call(passing(96) + bad_turns(4) + [left(1)])

      expect(gate).to include(verdict: 'INCOMPLETE_EVALUATION')
      expect(gate[:blockers]).to eq(['1 turn(s) not evaluated: a required check has no verdict (the rubric judge gave none)',
                                     '4 failed check(s) not triaged by a person'])
    end

    it 'are read from the status of the case as well as from the list' do
      by_status = turn(dialogue: 'by_status').merge('status' => 'not_evaluated')

      expect(described_class.call(passing(10) + [by_status])[:not_evaluated]).to eq(turns: 1, by_check: { 'judge' => 1 })
    end

    it 'leave the verdict as it was for a report that records no judge, and block a run that played without the judge' do
      expect(described_class.call(passing(10))[:verdict]).to eq('PASS')
      expect(described_class.call(passing(10), judge: true)[:verdict]).to eq('PASS')

      off = described_class.call(passing(10), judge: false)

      expect(off).to include(verdict: 'INCOMPLETE_EVALUATION', judge: false)
      expect(off[:blockers]).to eq(['the rubric judge was off: the text of the replies was not evaluated'])
    end

    it 'are asked for again by the rejudge: a turn that got its verdict is evaluated and the verdict is PASS' do
      judged = left(1).except('not_evaluated').merge('status' => 'pass')

      expect(described_class.call(passing(20) + [judged], judge: true)).to include(verdict: 'PASS', blockers: [])
    end
  end

  # Decision 3A: with RUNS=3 a dialogue passes only when all three runs pass (pass^3).
  describe 'repeated runs' do
    def runs_of(dialogues, count, fails_in: {})
      dialogues.flat_map do |name|
        Array.new(count) { |index| turn(dialogue: name, number: 1, run: index + 1, fails: fails_in.fetch([name, index + 1], [])) }
      end
    end

    let(:names) { Array.new(20) { |index| "dialogue_#{index}" } }

    it 'counts a turn that failed in one of the three runs as failed (pass^3), and reports the score of each run' do
      cases = runs_of(names, 3, fails_in: { ['dialogue_0', 2] => ['wrong_agent'], ['dialogue_1', 3] => ['wrong_agent'] })

      gate = described_class.call(cases)

      expect(gate[:overall]).to include(passed: 18, total: 20, pct: 90.0, failed_turns: 2, runs: 3)
      expect(gate[:blockers]).to include('overall 90.0% is below 95.0% (pass^3: a turn passes only when it passes in every run)')
      expect(gate[:runs].transform_values { |row| row.slice(:turns, :passed, :failed, :pct) }).to eq(
        1 => { turns: 20, passed: 20, failed: 0, pct: 100.0 }, 2 => { turns: 20, passed: 19, failed: 1, pct: 95.0 },
        3 => { turns: 20, passed: 19, failed: 1, pct: 95.0 }
      )
      expect(gate[:dialogues]).to include(runs: 3, total: 20, passed_every_run: 18, failed: 2, not_evaluated: 0, pass_k_pct: 90.0)
    end

    it 'passes a run in which every dialogue passed in every run, and counts the critical failures of all the runs' do
      clean = runs_of(names, 3) + [booking_turn.merge('run' => 1), person_turn.merge('run' => 1)]

      expect(described_class.call(clean)).to include(verdict: 'PASS')

      risky = runs_of(names, 3, fails_in: { ['dialogue_4', 3] => ['operation_mismatch:starts_at'] }) + clean.last(2)
      gate = described_class.call(risky)

      expect(gate[:critical]).to include(failed: 1)
      expect(gate[:runs][3]).to include(critical_failures: 1)
      expect(gate[:runs][1]).to include(critical_failures: 0)
      expect(gate[:verdict]).to eq('FAIL')
    end

    it 'calls a turn that failed in none of the runs but was left without a verdict in one not evaluated' do
      cases = runs_of(names, 3)
      cases[1] = cases[1].merge('status' => 'not_evaluated', 'not_evaluated' => ['judge'])

      gate = described_class.call(cases)

      expect(gate[:overall]).to include(passed: 19, total: 19, not_evaluated: 1)
      expect(gate[:dialogues]).to include(passed_every_run: 19, not_evaluated: 1, failed: 0)
    end
  end
end
