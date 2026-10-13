# frozen_string_literal: true

require 'rails_helper'

# A dialogue that went another way than the fixture counted on. The fixture states what each turn does when the turn before it did what it
# should; when an earlier turn deviated (a booking that was not made, a conversation handed to the wrong colleague, a part left open), the
# turns after it are held to the state the dialogue is in, so one deviation is reported once and not on every turn after it.
RSpec.describe Captain::Evals::RoutingBenchmark::Scorer, 'after an earlier deviation' do
  let(:account) { create(:account) }
  let(:planner) { create(:captain_assistant, account: account, name: 'Администратор') }
  let(:owner) { create(:captain_assistant, account: account, name: 'Запись к врачу') }
  let(:other) { create(:captain_assistant, account: account, name: 'Цены и услуги') }
  let(:contact) { create(:contact, account: account, name: 'Гульнар Тлеуова') }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:resource) { create(:scheduling_resource, account: account, name: 'Терапевт Нурланова Асель') }
  let(:scorer) { described_class.new(account: account, conversation: conversation) }
  let(:event_class) { Struct.new(:event_name, :tool_name, :payload, :assistant_id, :status, :reason) }
  let(:no_operations) { described_class::OPERATION_MODELS.keys.index_with { {} } }
  let(:friday_noon) { Time.iso8601('2026-10-16T12:00:00+05:00') }
  let(:saturday_ten) { Time.iso8601('2026-10-17T10:00:00+05:00') }

  before do
    planner
    owner
    other
  end

  def booking(start, kind: 'create', **more)
    { 'model' => 'appointment', 'kind' => kind, 'params' => { 'status' => 'scheduled', 'starts_at' => start.iso8601 } }.merge(more.stringify_keys)
  end

  def move(from, to) = booking(to, kind: 'update', previous_starts_at: from.iso8601)

  def book(starts_at, **attributes)
    create(:scheduling_appointment, account: account, resource: resource, contact: contact, client_name: contact.name, starts_at: starts_at,
                                    ends_at: starts_at + 30.minutes, **attributes)
  end

  def tool_event(name, agent: owner, success: true)
    event_class.new('llm.tool.complete', name, { 'result_success' => success }, agent.id)
  end

  def coordination(name, payload = {}) = event_class.new(name, nil, payload, nil, nil, nil)

  def snapshot
    described_class::OPERATION_MODELS.transform_values { |model| model.where(account_id: account.id).pluck(:id, :updated_at).to_h }
  end

  def state
    rows = Scheduling::Appointment.where(account_id: account.id).pluck(:id, :resource_id, :service_id, :starts_at, :status)
    { 'appointment' => rows.to_h { |id, resource_id, service, start, status| [id, { 'resource_id' => resource_id, 'service_id' => service, 'starts_at' => start, 'status' => status }] } }
  end

  # One turn of the dialogue: the snapshots, then the block writes the rows, then the scored turn.
  def play(text, expect: {}, events: [], agent: owner, routing: nil, **extra)
    before = snapshot
    before_state = state
    yield if block_given?
    turn = { 'customer' => 'Здравствуйте', 'expect' => { 'agent' => agent.name, 'council' => false }.merge(expect.stringify_keys) }
    response = { 'agent_id' => agent.id, 'response' => text, 'captain_request_id' => 'synthetic-request' }.merge(extra.stringify_keys)
    scorer.call(turn: turn, response: response, events: events, before: before, before_state: before_state, routing: routing)
  end

  def failure_ids(result) = result[:failures].pluck(:id)

  def severity_of(result, id) = result[:failures].find { |failure| failure[:id] == id }&.dig(:severity)

  describe 'a booking that an earlier turn did not make' do
    let(:forbids_booking) { { operations: [], must_not_call: ['create_appointment'] } }

    # Turn 1: the agent asks the patient to confirm instead of booking.
    let!(:first_turn) { play('Подтвердите, пожалуйста, запись?', expect: { operations: [booking(friday_noon)] }) }

    it 'is reported once, at the turn that did not make it (missing_operation)' do
      expect(failure_ids(first_turn)).to eq(['missing_operation:appointment'])
    end

    it 'comes late on the next turn: late_operation (important) instead of the critical forbidden_tool and unexpected_mutation' do
      result = play('Записала вас на 16 октября в 12:00.', expect: forbids_booking, events: [tool_event('create_appointment')]) { book(friday_noon) }

      expect(failure_ids(result)).to eq(['late_operation:create_appointment'])
      expect(severity_of(result, 'late_operation:create_appointment')).to eq('important')
      expect(result[:failures].first).to include(gate: 'overall')
      expect(result[:failures].first[:detail]).to include('an earlier turn expected')
      expect(result[:warnings]).to include('late_operation')
    end

    it 'is accounted for where the fixture lists no forbidden tool either: no unexpected_mutation, and a warning that it came late' do
      result = play('Записала вас на 16 октября в 12:00.', expect: { operations: [] }, events: [tool_event('create_appointment')]) { book(friday_noon) }

      expect(failure_ids(result)).to be_empty
      expect(result[:warnings]).to eq(['late_operation'])
    end

    it 'is spent once it came: the next booking of the same time is a forbidden one again' do
      play('Записала вас.', expect: forbids_booking, events: [tool_event('create_appointment')]) { book(friday_noon) }

      result = play('Записала вас ещё раз.', expect: forbids_booking, events: [tool_event('create_appointment')]) { book(friday_noon + 2.days) }

      expect(failure_ids(result)).to eq(['forbidden_tool:create_appointment'])
      expect(severity_of(result, 'forbidden_tool:create_appointment')).to eq('critical')
    end

    it 'stays a critical forbidden_tool when the row is not the one that was expected' do
      result = play('Записала вас.', expect: forbids_booking, events: [tool_event('create_appointment')]) { book(friday_noon + 1.hour) }

      expect(failure_ids(result)).to eq(['forbidden_tool:create_appointment'])
      expect(severity_of(result, 'forbidden_tool:create_appointment')).to eq('critical')
      expect(result[:warnings]).not_to include('late_operation')
    end

    it 'is an unexpected_mutation where the fixture does not list the tool as forbidden, when the row is not the one that was expected' do
      result = play('Записала вас.', expect: { operations: [] }, events: [tool_event('create_appointment')]) { book(friday_noon + 1.hour) }

      expect(failure_ids(result)).to eq(['unexpected_mutation'])
    end

    it 'is no late booking when one of two rows is the wrong one' do
      result = play('Записала вас.', expect: forbids_booking, events: Array.new(2) { tool_event('create_appointment') }) do
        book(friday_noon)
        book(friday_noon + 3.hours)
      end

      expect(failure_ids(result)).to eq(['forbidden_tool:create_appointment'])
      expect(severity_of(result, 'forbidden_tool:create_appointment')).to eq('critical')
    end

    it 'does not excuse a tool that failed or a booking that no tool made' do
      failed = play('Не получилось.', expect: forbids_booking, events: [tool_event('create_appointment', success: false)])

      expect(failure_ids(failed)).to eq(['forbidden_tool:create_appointment'])
      expect(severity_of(failed, 'forbidden_tool:create_appointment')).to eq('important')
    end
  end

  describe 'a move of a booking that was never made (the correction turn)' do
    let(:correction) do
      { operations: [move(friday_noon, saturday_ten)], must_call: ['update_appointment'], must_not_call: ['create_appointment'],
        acts: [{ 'tool' => 'update_appointment', 'agent' => 'Запись к врачу' }] }
    end

    before { play('Подтвердите, пожалуйста, запись?', expect: { operations: [booking(friday_noon)] }) }

    # The corrected time is where the booking is made: it is the booking itself, so it is no missing move, no missing tool, no missing act, no
    # critical forbidden booking and no unexpected row.
    it 'is folded into the booking: the agent that books at the corrected time fails nothing but late_operation' do
      result = play('Вы записаны на 17 октября в 10:00.', expect: correction, events: [tool_event('create_appointment')]) { book(saturday_ten) }

      expect(failure_ids(result)).to eq(['late_operation:create_appointment'])
      expect(severity_of(result, 'late_operation:create_appointment')).to eq('important')
    end

    it 'still holds the booking to the corrected time, the doctor and the service that the move pins' do
      result = play('Вы записаны на 17 октября в 11:00.', expect: correction, events: [tool_event('create_appointment')]) { book(saturday_ten + 1.hour) }

      expect(failure_ids(result)).to include('operation_mismatch:starts_at')
      expect(severity_of(result, 'operation_mismatch:starts_at')).to eq('critical')
    end

    it 'keeps the booking pending, at the corrected time, when the agent made none' do
      play('Какое время вам подходит?', expect: correction)

      result = play('Вы записаны на 17 октября в 10:00.', expect: { operations: [], must_not_call: ['create_appointment'] },
                                                         events: [tool_event('create_appointment')]) { book(saturday_ten) }

      expect(failure_ids(result)).to eq(['late_operation:create_appointment'])
    end

    it 'leaves a move of an appointment that exists alone: nothing is pending for it' do
      appointment = book(friday_noon + 7.days)
      move_it = move(friday_noon + 7.days, saturday_ten)

      result = play('Перенесла на 17 октября в 10:00.', expect: { operations: [move_it], must_call: ['update_appointment'] },
                                                          events: [tool_event('update_appointment')]) do
        appointment.update!(starts_at: saturday_ten, ends_at: saturday_ten + 30.minutes)
      end

      expect(failure_ids(result)).to be_empty
    end
  end

  describe 'previous_starts_at of a move' do
    let(:seeded_start) { Time.iso8601('2026-10-19T09:00:00+05:00') }
    let(:appointment) { book(seeded_start) }

    # Turn 1 moves the appointment of the fixture to 14:00; turn 2 is the correction "лучше на 15:00". The fixture names the appointment by the
    # start it had at the beginning (09:00), the row stands at 14:00 when the turn begins.
    before do
      appointment
      play('Перенесла на 14:00.', expect: { operations: [move(seeded_start, seeded_start + 5.hours)] }, events: [tool_event('update_appointment')]) do
        appointment.update!(starts_at: seeded_start + 5.hours, ends_at: seeded_start + 5.hours + 30.minutes)
      end
    end

    it 'is met by the first start the dialogue saw of the appointment, not only by its start before the turn' do
      result = play('Перенесла на 15:00.', expect: { operations: [move(seeded_start, seeded_start + 6.hours)] }, events: [tool_event('update_appointment')]) do
        appointment.update!(starts_at: seeded_start + 6.hours, ends_at: seeded_start + 6.hours + 30.minutes)
      end

      expect(failure_ids(result)).to be_empty
    end

    it 'is met by the start before the turn as well' do
      result = play('Перенесла на 15:00.', expect: { operations: [move(seeded_start + 5.hours, seeded_start + 6.hours)] },
                                           events: [tool_event('update_appointment')]) do
        appointment.update!(starts_at: seeded_start + 6.hours, ends_at: seeded_start + 6.hours + 30.minutes)
      end

      expect(failure_ids(result)).to be_empty
    end

    it 'is a mismatch for a start the appointment never had' do
      result = play('Перенесла на 15:00.', expect: { operations: [move(seeded_start + 1.hour, seeded_start + 6.hours)] },
                                           events: [tool_event('update_appointment')]) do
        appointment.update!(starts_at: seeded_start + 6.hours, ends_at: seeded_start + 6.hours + 30.minutes)
      end

      expect(failure_ids(result)).to eq(['operation_mismatch:previous_starts_at'])
    end

    it 'knows the first start of an appointment that the dialogue itself created' do
      created = nil
      play('Записала вас на 17:00.', expect: { operations: [booking(seeded_start + 8.hours)] }, events: [tool_event('create_appointment')]) do
        created = book(seeded_start + 8.hours)
      end
      play('Перенесла на 18:00.', expect: { operations: [move(seeded_start + 8.hours, seeded_start + 9.hours)] }, events: [tool_event('update_appointment')]) do
        created.update!(starts_at: seeded_start + 9.hours, ends_at: seeded_start + 9.hours + 30.minutes)
      end

      result = play('Перенесла на 19:00.', expect: { operations: [move(seeded_start + 8.hours, seeded_start + 10.hours)] },
                                           events: [tool_event('update_appointment')]) do
        created.update!(starts_at: seeded_start + 10.hours, ends_at: seeded_start + 10.hours + 30.minutes)
      end

      expect(failure_ids(result)).to be_empty
    end
  end

  describe 'one row for one expectation' do
    let(:friday_two) { friday_noon + 2.hours }

    it 'reports the second of two bookings as missing when only the first was made, not as a wrong answer to it (the row was claimed)' do
      result = play('Записала вас на 12:00.', expect: { operations: [booking(friday_noon), booking(friday_two)] }, events: [tool_event('create_appointment')]) do
        book(friday_noon)
      end

      expect(failure_ids(result)).to eq(['missing_operation:appointment'])
      expect(severity_of(result, 'missing_operation:appointment')).to eq('important')
    end

    it 'does so whichever of the two expectations the row meets' do
      result = play('Записала вас на 14:00.', expect: { operations: [booking(friday_noon), booking(friday_two)] }, events: [tool_event('create_appointment')]) do
        book(friday_two)
      end

      expect(failure_ids(result)).to eq(['missing_operation:appointment'])
    end

    it 'passes two bookings that meet the two expectations' do
      result = play('Записала вас на 12:00 и на 14:00.', expect: { operations: [booking(friday_noon), booking(friday_two)] },
                                                       events: Array.new(2) { tool_event('create_appointment') }) do
        book(friday_two)
        book(friday_noon)
      end

      expect(failure_ids(result)).to be_empty
    end

    it 'compares an expectation that no exact row meets with the rows nobody claimed' do
      result = play('Записала вас.', expect: { operations: [booking(friday_noon), booking(friday_two)] },
                                     events: Array.new(2) { tool_event('create_appointment') }) do
        book(friday_noon)
        book(friday_two + 1.hour)
      end

      expect(failure_ids(result)).to eq(['operation_mismatch:starts_at'])
      expect(severity_of(result, 'operation_mismatch:starts_at')).to eq('critical')
    end

  end

  describe 'expect.transfers after the first turn' do
    let(:to_other) { [coordination('captain.agent.transfer', { 'from_agent_id' => planner.id, 'to_agent_id' => other.id })] }
    let(:back_to_owner) { [coordination('captain.agent.transfer', { 'from_agent_id' => other.id, 'to_agent_id' => owner.id })] }
    let(:wrongly_held) { { before: { current_assistant_id: other.id, routing_revision: 1 }, after: { current_assistant_id: owner.id, routing_revision: 2 } } }
    let(:rightly_held) { { before: { current_assistant_id: owner.id, routing_revision: 1 }, after: { current_assistant_id: owner.id, routing_revision: 1 } } }

    before do
      first = play('Цена 9000 ₸.', agent: other, events: to_other, expect: { agent: 'Запись к врачу', transfers: 1 },
                                   routing: { before: { current_assistant_id: planner.id, routing_revision: 0 },
                                              after: { current_assistant_id: other.id, routing_revision: 1 } })
      expect(failure_ids(first)).to eq(['wrong_agent'])
    end

    it 'counts the first turn as the fixture says' do
      fresh = described_class.new(account: account, conversation: conversation)
      turn = { 'customer' => 'Здравствуйте', 'expect' => { 'agent' => 'Запись к врачу', 'council' => false, 'transfers' => 1 } }
      result = fresh.call(turn: turn, response: { 'agent_id' => owner.id, 'response' => 'Здравствуйте!', 'captain_request_id' => 'r' }, events: [],
                          before: no_operations, routing: rightly_held)

      expect(failure_ids(result)).to eq(['wrong_transfers:0'])
    end

    it 'expects the transfer that brings the conversation to the expected agent, when an earlier turn left it with another one' do
      result = play('Ответ.', events: back_to_owner, expect: { agent: 'Запись к врачу', transfers: 0 }, routing: wrongly_held)

      expect(failure_ids(result)).to be_empty
    end

    it 'expects no transfer when the holder is already an expected agent, whatever the fixture counted' do
      stays = play('Ответ.', expect: { agent: 'Запись к врачу', transfers: 1 }, routing: rightly_held)
      moves = play('Ответ.', events: back_to_owner, expect: { agent: 'Запись к врачу', transfers: 1 }, routing: rightly_held)

      expect(failure_ids(stays)).to be_empty
      expect(failure_ids(moves)).to eq(['wrong_transfers:1'])
    end

    it 'expects no transfer in a council: a council never changes hands' do
      held = wrongly_held.merge(after: wrongly_held[:before])
      council = { agent: 'Запись к врачу', council: true, transfers: 1 }

      silent = play('Ответ.', events: [coordination('captain.council.started')], expect: council, agent: other, routing: held)
      moved = play('Ответ.', events: [coordination('captain.council.started')] + back_to_owner, expect: council, agent: other, routing: held)

      expect(failure_ids(silent)).not_to include('wrong_transfers:0')
      expect(failure_ids(moved)).to include('wrong_transfers:1')
    end

    it 'checks nothing when the fixture does not say, and keeps the fixture count when the turn has no routing' do
      expect(failure_ids(play('Ответ.', events: back_to_owner, expect: { agent: 'Запись к врачу' }, routing: wrongly_held))).to be_empty
      expect(failure_ids(play('Ответ.', expect: { agent: 'Запись к врачу', transfers: 1 }))).to eq(['wrong_transfers:0'])
    end
  end

  describe 'a council that the fixture does not expect, after a part was left open' do
    let(:part) do
      { 'part_id' => 'p1-aaaaaaaaaaaa', 'part_version' => 1, 'executor_agent_id' => owner.id }
    end

    def council_turn(state)
      events = [coordination('captain.council.started', { 'participants' => [planner.id, owner.id] }),
                coordination('captain.council.part_started', part.merge('lane' => 'write')),
                coordination('captain.council.part_finished', part.merge('state' => state, 'acted' => false))]
      play('Ответ.', agent: planner, events: events, expect: { agent: 'Администратор', council: true })
    end

    def follow_up
      play('Хорошо, на 10:00.', agent: planner, events: [coordination('captain.council.started')], expect: { agent: 'Администратор', council: false })
    end

    %w[waiting_customer unknown].each do |open_state|
      it "is no council_unexpected after a part that ended #{open_state}: the message answers it, and the runtime starts a council to run it again" do
        council_turn(open_state)

        expect(failure_ids(follow_up)).to be_empty
      end
    end

    it 'is a council_unexpected after parts that are closed' do
      council_turn('done')

      expect(failure_ids(follow_up)).to eq(['council_unexpected'])
    end

    it 'is a council_unexpected when no turn has left a part open' do
      expect(failure_ids(follow_up)).to eq(['council_unexpected'])
    end

    it 'forgets a part that a later council closed' do
      council_turn('waiting_customer')
      council_turn('done')

      expect(failure_ids(follow_up)).to eq(['council_unexpected'])
    end
  end
end
