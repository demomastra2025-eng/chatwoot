# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::DoneActions do
  let(:request) { 'request:41' }
  let(:appointment) do
    { success: true, appointment_id: 984, doctor_name: 'Терапевт Абдрахманова Сауле', local_date: '15.10.2026', local_time: '11:00',
      status: 'updated' }
  end

  def entry_for(tool, result, arguments: {})
    described_class.entry(tool_name: tool, arguments: arguments, result: result, request: request)
  end

  describe '.entry' do
    it 'writes a reschedule with the specialist and the new moment as the tool returned them' do
      expect(entry_for('update_appointment', JSON.generate(appointment))).to eq(
        'tool' => 'update_appointment', 'label' => 'Rescheduled',
        'text' => 'Терапевт Абдрахманова Сауле, now Thu 15.10.2026 11:00', 'request' => 'request:41'
      )
    end

    it 'writes a booking and a cancellation with the specialist and the moment' do
      booked = entry_for('create_appointment', JSON.generate(appointment.merge(status: 'created', local_date: '16.10.2026', local_time: '09:00')))
      cancelled = entry_for('cancel_appointment', JSON.generate(appointment.merge(status: 'cancelled')))

      expect(booked).to include('label' => 'Booked', 'text' => 'Терапевт Абдрахманова Сауле, Fri 16.10.2026 09:00')
      expect(cancelled).to include('label' => 'Cancelled appointment', 'text' => 'Терапевт Абдрахманова Сауле, Thu 15.10.2026 11:00')
    end

    it 'reads the name of a tool of an agent with a prefix' do
      expect(entry_for('agent__update_appointment', JSON.generate(appointment))).to include('tool' => 'update_appointment')
    end

    it 'writes nothing for an update that changed nothing' do
      expect(entry_for('update_appointment', JSON.generate(appointment.merge(status: 'unchanged')))).to be_nil
    end

    it 'writes a change that the provider has not confirmed as a request, never as done' do
      pending_move = appointment.merge(success: false, reason: 'pending_provider_confirmation', status: 'pending_provider_confirmation',
                                       requested_local_date: '16.10.2026', requested_local_time: '10:00')

      expect(entry_for('update_appointment', JSON.generate(pending_move))).to include(
        'label' => 'Reschedule requested', 'text' => 'Терапевт Абдрахманова Сауле, Fri 16.10.2026 10:00, awaiting confirmation'
      )
    end

    it 'writes the deals with the title and the amount as stored, and the stage a deal was moved to' do
      deal = { action: 'create_deal', deal_id: 8, title: 'Имплантация', amount: '150000', currency: 'KZT', deal: { id: 8 } }
      moved = deal.merge(action: 'transition_deal_stage', current_stage: { id: 3, name: 'Консультация' })

      expect(entry_for('create_deal', JSON.pretty_generate(deal))).to include('label' => 'Created deal', 'text' => '«Имплантация», 150000 KZT')
      expect(entry_for('update_deal', JSON.pretty_generate(deal))).to include('label' => 'Updated deal')
      expect(entry_for('transition_deal_stage', JSON.pretty_generate(moved))).to include(
        'label' => 'Moved deal', 'text' => '«Имплантация», 150000 KZT, stage «Консультация»'
      )
    end

    it 'writes the tasks and the companies by title and name' do
      task = JSON.pretty_generate(action: 'create_task', task_id: 5, title: 'Позвонить пациенту', task: { id: 5 })
      company = JSON.pretty_generate(action: 'create_company', company_id: 6, name: 'ООО Ромашка', company: { id: 6 })

      expect(entry_for('create_task', task)).to include('label' => 'Created task', 'text' => '«Позвонить пациенту»')
      expect(entry_for('create_company', company)).to include('label' => 'Created company', 'text' => '«ООО Ромашка»')
    end

    it 'names the patient data that was updated by field and never writes a value' do
      arguments = { first_name: 'Анна', phone_number: '+77001112233', iin: '', email: nil }

      entry = entry_for('update_my_contact', JSON.generate(success: true, contact: { name: 'Анна' }), arguments: arguments)

      expect(entry).to include('label' => 'Updated patient data', 'text' => 'first name, phone number')
      expect(entry.to_json).not_to include('Анна', '+7700')
    end

    it 'writes nothing for a tool that is not an action of the patient record or the calendar' do
      %w[faq_lookup search_deals add_private_note handoff resolve_conversation].each do |tool|
        expect(entry_for(tool, JSON.generate(success: true, title: 'x'))).to be_nil
      end
    end

    it 'never raises: the list helps the model and must not fail a tool call' do
      allow(Captain::Runtime::ToolFailure).to receive(:facts).and_raise(StandardError, 'boom')

      expect(entry_for('update_appointment', JSON.generate(appointment))).to be_nil
      expect(described_class.entry(tool_name: nil, arguments: nil, result: nil, request: nil)).to be_nil
    end

    it 'names an action that returned no details by its label alone' do
      expect(entry_for('cancel_appointment', JSON.generate(success: true))).to include('label' => 'Cancelled appointment', 'text' => '')
    end

    it 'keeps a record short' do
      long = JSON.generate(appointment.merge(doctor_name: 'Х' * 500))

      expect(entry_for('update_appointment', long)['text'].length).to eq(described_class::TEXT_LIMIT)
    end
  end

  describe '.remember' do
    def record(number)
      { 'tool' => 'create_deal', 'label' => 'Created deal', 'text' => "«Сделка #{number}»", 'request' => request }
    end

    it 'puts the newest first and keeps five' do
      list = (1..7).reduce([]) { |entries, number| described_class.remember(entries, record(number)) }

      expect(list.pluck('text')).to eq((3..7).reverse_each.map { |number| "«Сделка #{number}»" })
    end

    it 'does not write the newest record twice, and keeps the list when there is nothing to add' do
      list = described_class.remember([record(1)], record(1))

      expect(list).to eq([record(1)])
      expect(described_class.remember(list, nil)).to eq(list)
      expect(described_class.remember(nil, nil)).to eq([])
    end
  end

  describe '.lines' do
    let(:entries) do
      [{ 'label' => 'Rescheduled', 'text' => 'Терапевт Абдрахманова Сауле, now Thu 15.10.2026 11:00', 'request' => 'request:41' },
       { 'label' => 'Booked', 'text' => 'Терапевт Абдрахманова Сауле, Tue 13.10.2026 15:00', 'request' => 'request:30' }]
    end

    it 'is a header and one line per action, newest first, marked as done in reply to this message or earlier' do
      expect(described_class.lines(entries: entries, request: 'request:41')).to eq(
        ['Done in this conversation:',
         '- Rescheduled: Терапевт Абдрахманова Сауле, now Thu 15.10.2026 11:00 (in reply to this message)',
         '- Booked: Терапевт Абдрахманова Сауле, Tue 13.10.2026 15:00 (earlier)']
      )
    end

    it 'marks every action earlier when the request is another one, or unknown' do
      expect(described_class.lines(entries: entries, request: 'request:42').grep(/earlier/).size).to eq(2)
      expect(described_class.lines(entries: entries, request: nil).grep(/in reply/)).to be_empty
    end

    it 'shows at most five actions' do
      many = Array.new(8) { |index| { 'label' => 'Created deal', 'text' => "«#{index}»", 'request' => 'request:1' } }

      expect(described_class.lines(entries: many, request: 'request:1').size).to eq(1 + described_class::LIMIT)
    end

    it 'renders nothing when nothing was done' do
      expect(described_class.lines(nil)).to eq([])
      expect(described_class.lines(entries: [], request: 'request:41')).to eq([])
    end

    it 'writes an action without details as its label' do
      expect(described_class.lines(entries: [{ 'label' => 'Booked', 'text' => '', 'request' => 'request:1' }], request: 'request:1').last)
        .to eq('- Booked (in reply to this message)')
    end
  end

  describe '.for_run' do
    it 'gives the list and the request the run answers: the last message of the fence, else the id of the request' do
      entries = [{ 'label' => 'Booked', 'text' => '', 'request' => 'request:9' }]

      with_fence = { done_actions: entries, state: { captain_response_fence: { last_message_id: 9 } }, agent_request_id: 'abc' }
      without_fence = { done_actions: entries, state: {}, agent_request_id: 'abc' }

      expect(described_class.for_run(with_fence)).to eq(entries: entries, request: 'request:9')
      expect(described_class.for_run(without_fence)).to eq(entries: entries, request: 'request:abc')
    end

    it 'gives nothing for a run that did nothing yet' do
      expect(described_class.for_run(nil)).to be_nil
      expect(described_class.for_run({ state: {} })).to be_nil
      expect(described_class.for_run({ done_actions: [] })).to be_nil
    end
  end
end
