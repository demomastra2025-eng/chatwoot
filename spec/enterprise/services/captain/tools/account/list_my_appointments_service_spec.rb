require 'rails_helper'

RSpec.describe Captain::Tools::Account::ListMyAppointmentsService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:tool_context) { Struct.new(:state, :context).new({ conversation: { id: conversation.id } }, {}) }

  before { account.enable_features!('scheduling') }

  def call_tool(**arguments)
    adapter = Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'list_my_appointments')
    JSON.parse(adapter.execute(tool_context, **arguments))
  end

  it 'returns the appointments of the current contact across conversations, without the data of the system' do
    own = create(:scheduling_appointment, account: account, contact: contact, external_ref: 'private-command')
    another_channel = create(:conversation, account: account, contact: contact)
    other_own = create(:scheduling_appointment, account: account, contact: contact, patient_contact: contact,
                                                conversation: another_channel)
    other_contact = create(:contact, account: account)
    create(:scheduling_appointment, account: account, contact: other_contact, conversation: conversation)
    create(:scheduling_appointment, account: account, contact: other_contact, patient_contact: contact)
    create(:scheduling_appointment, account: create(:account))

    payload = call_tool
    expect(payload).to include('success' => true, 'total' => 2, 'has_more' => false)
    expect(payload.fetch('appointments').pluck('id')).to contain_exactly(own.id, other_own.id)
    expect(payload.fetch('appointments').first.keys).to match_array(%w[id status date time doctor service])
    expect(payload.to_json).not_to include('private-command', 'payment_status', 'client_phone')
  end

  # Suggestion eval 27.10 (c76-1231671): a parent asked to cancel the visit of a child that was booked from the parent's chat; the
  # lookup returned the parent's own cards only and both drafts told the patient there was nothing to cancel.
  it 'returns the appointments booked from this chat for another patient, names the patient and gives the token that a change needs' do
    child = create(:contact, account: account, name: 'Айя')
    own = create(:scheduling_appointment, account: account, contact: contact, starts_at: 2.days.from_now)
    child_visit = create(:scheduling_appointment, account: account, contact: contact, patient_contact: child, client_name: 'Ким Айя',
                                                  starts_at: 1.day.from_now, ends_at: 1.day.from_now + 30.minutes)

    payload = call_tool(status: 'scheduled')

    expect(payload).to include('success' => true, 'total' => 2)
    cards = payload.fetch('appointments').index_by { |card| card['id'] }
    expect(cards.fetch(child_visit.id)).to include('patient_name' => 'Ким Айя', 'status' => 'scheduled', 'appointment_access_token' => be_present)
    expect(cards.fetch(own.id)).not_to have_key('patient_name')
    expect(cards.fetch(own.id)).not_to have_key('appointment_access_token')
    expect(Captain::Tools::Agent::AppointmentAccess.resolve(token: cards.fetch(child_visit.id).fetch('appointment_access_token'),
                                                            assistant: assistant, conversation: conversation,
                                                            appointment_id: child_visit.id)).to eq(child_visit)
  end

  # Review of quality-fixes-1 (H1): the circle of the patient selector is no proof of identity.
  it 'does not list the visits of a patient who books from their own chat, also when this contact once booked that patient' do
    adult = create(:contact, account: account, name: 'Дина')
    booked_once = create(:scheduling_appointment, account: account, contact: contact, patient_contact: adult, client_name: 'Дина',
                                                  starts_at: 3.days.from_now)
    create(:scheduling_appointment, account: account, contact: adult, patient_contact: adult, client_name: 'Дина', starts_at: 5.days.from_now)
    create(:scheduling_appointment, account: account, contact: adult, patient_contact: adult, client_name: 'Дина', status: 'completed',
                                    starts_at: 40.days.ago, ends_at: 40.days.ago + 30.minutes)

    payload = call_tool

    expect(payload.fetch('appointments').pluck('id')).to eq([booked_once.id])
    expect(call_tool(status: 'completed')).to include('total' => 0, 'appointments' => [])
  end

  it 'tells the agent that nothing found is no proof of the absence of a booking, so it never says there is nothing to cancel' do
    payload = call_tool(status: 'scheduled')

    expect(payload).to include('success' => true, 'total' => 0, 'appointments' => [])
    expect(payload.fetch('note')).to include('does not prove', 'Never tell the patient', 'nothing to cancel', 'search_appointments', 'staff')
  end

  it 'returns neutral failures for invalid filters and a missing contact' do
    expect(call_tool(status: 'private')).to eq('success' => false, 'reason' => 'validation_error', 'error_class' => 'business')
    expect(call_tool(limit: -1)).to eq('success' => false, 'reason' => 'validation_error', 'error_class' => 'business')
    expect(call_tool(date_from: '2026-10-10T12:00:00Z')).to eq('success' => false, 'reason' => 'validation_error', 'error_class' => 'business')
    expect(call_tool(date_to: '2026-02-30')).to eq('success' => false, 'reason' => 'validation_error', 'error_class' => 'business')
    absent_context = Struct.new(:state, :context).new({ conversation: { id: 2_147_483_647 } }, {})
    adapter = Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'list_my_appointments')
    expect(JSON.parse(adapter.execute(absent_context))).to eq('success' => false, 'reason' => 'not_found')
  end
end
