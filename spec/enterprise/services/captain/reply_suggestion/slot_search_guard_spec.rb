# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::SlotSearchGuard do
  let(:account) { create(:account) }
  let(:resource) { create(:scheduling_resource, account: account, name: 'Жанат Есен', timezone: 'Asia/Almaty') }
  let(:cache_key) { Captain::Runtime::ToolWrapper::SUGGESTION_READ_CACHE_KEY }
  let(:searched_times) { %w[14:30 15:00 15:30 16:00 16:30] }
  let(:searched_day) { { resource_id: resource.id, name: resource.name, date: '2026-10-31', times: searched_times, more: 0 } }
  let(:context) do
    answer = { duration_min: 30, total: 5, days: [searched_day] }
    {
      :state => { account_id: account.id },
      cache_key => { 'digest' => { tool: 'search_available_slots', result: { success: true, message: JSON.generate(answer) } } }
    }
  end

  def refusal(tool_name, arguments, run_context = context)
    described_class.refusal(tool_name: tool_name, arguments: arguments, context: run_context)
  end

  describe 'a booking' do
    # Suggestion eval 26.10, Intermedical: the search listed 14:30-16:30 on 31.10 and a card was prepared for the 14:20 the patient wrote.
    it 'is refused at a start that the search of the run did not return, and names the exact search to make' do
      result = refusal('create_appointment', { resource_id: resource.id, starts_at: '2026-10-31T14:20' })

      expect(result).to include(success: false, retryable: true)
      expect(result[:error]).to include('14:20 on 2026-10-31', "resource_id #{resource.id}", 'not returned by search_available_slots in this run',
                                        'from = to = 2026-10-31T14:20')
      expect(result[:data]).to eq(code: 'slot_not_searched', resource_id: resource.id, starts_at: '2026-10-31T14:20',
                                  next_tool: 'search_available_slots')
      expect(result[:audit]).to include(failure_stage: 'tool_arguments', failure_reason: 'slot_not_searched', mutation_executed: false)
    end

    it 'goes on at a start that the search returned, written as a local time or as the exact ISO start of the slot' do
      expect(refusal('create_appointment', { resource_id: resource.id, starts_at: '2026-10-31T14:30' })).to be_nil
      expect(refusal('create_appointment', { resource_id: resource.id, starts_at: '2026-10-31T16:30:00+05:00' })).to be_nil
      expect(refusal('create_appointment', { resource_id: resource.id, starts_at: '2026-10-31T11:30:00Z' })).to be_nil
    end

    it 'is refused for a run that searched nothing, and goes on after the search of that exact time' do
      expect(refusal('create_appointment', { resource_id: resource.id, starts_at: '2026-10-31T14:20' }, { state: { account_id: account.id } }))
        .to include(success: false)

      exact = { success: true, message: JSON.generate(days: [{ resource_id: resource.id, date: '2026-10-31', times: ['14:20'], more: 0 }]) }
      context[cache_key]['digest-exact'] = { tool: 'search_available_slots', result: exact }

      expect(refusal('create_appointment', { resource_id: resource.id, starts_at: '2026-10-31T14:20' })).to be_nil
    end

    it 'is not decided here when the specialist or the time cannot be resolved: the validation of the card reports it' do
      expect(refusal('create_appointment', { resource_id: 0, starts_at: '2026-10-31T14:20' })).to be_nil
      expect(refusal('create_appointment', { resource_id: resource.id + 1000, starts_at: '2026-10-31T14:20' })).to be_nil
      expect(refusal('create_appointment', { resource_id: resource.id, starts_at: 'завтра в два' })).to be_nil
      expect(refusal('create_appointment', { resource_id: resource.id })).to be_nil
      expect(refusal('create_appointment', { resource_id: resource.id, starts_at: '2026-10-31T14:20' }, { state: { account_id: 0 } })).to be_nil
    end

    it 'leaves the other tools alone' do
      expect(refusal('cancel_appointment', { appointment_id: 1, starts_at: '2026-10-31T14:20' })).to be_nil
      expect(refusal('create_task', { resource_id: resource.id, starts_at: '2026-10-31T14:20' })).to be_nil
    end
  end

  describe 'a move' do
    let(:appointment) do
      create(:scheduling_appointment, account: account, resource: resource, starts_at: Time.zone.parse('2026-10-30T10:00:00+05:00'))
    end

    it 'is refused to a start that the search did not return, for the specialist of the appointment' do
      result = refusal('update_appointment', { appointment_id: appointment.id, starts_at: '2026-10-31T14:20' })

      expect(result[:data]).to include(code: 'slot_not_searched', resource_id: resource.id)
      expect(refusal('update_appointment', { appointment_id: appointment.id, starts_at: '2026-10-31T15:00' })).to be_nil
    end

    it 'is checked for the new specialist when the call names one' do
      other = create(:scheduling_resource, account: account, name: 'Д-р Ли', timezone: 'Asia/Almaty')

      expect(refusal('update_appointment', { appointment_id: appointment.id, resource_id: other.id, starts_at: '2026-10-31T15:00' }))
        .to include(success: false)
    end

    it 'needs no search for the start the appointment already has, a comment change or an appointment it cannot find' do
      expect(refusal('update_appointment', { appointment_id: appointment.id, starts_at: '2026-10-30T10:00' })).to be_nil
      expect(refusal('update_appointment', { appointment_id: appointment.id, client_comment: 'позвонить' })).to be_nil
      expect(refusal('update_appointment', { appointment_id: appointment.id + 1000, starts_at: '2026-10-31T14:20' })).to be_nil
      expect(refusal('update_appointment', { starts_at: '2026-10-31T14:20' })).to be_nil
    end
  end

  it 'never blocks a call because the check itself failed' do
    allow(Captain::ReplySuggestion::SearchedSlots).to receive(:new).and_raise(RuntimeError, 'boom')

    expect(refusal('create_appointment', { resource_id: resource.id, starts_at: '2026-10-31T14:20' })).to be_nil
  end
end
