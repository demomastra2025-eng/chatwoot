require 'rails_helper'

RSpec.describe Captain::Tools::CancelAppointmentTool do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:run_context) do
    instance_double(Captain::Runtime::RunContext, context: { state: { conversation: { id: conversation.id } } })
  end
  let(:tool_context) { Captain::Runtime::ToolContext.new(run_context: run_context) }
  let(:missing_id) { 2_147_483_647 }
  let(:neutral_failure) { { 'success' => false, 'reason' => 'not_found', 'error_class' => 'business' } }

  before do
    account.enable_features!('scheduling')
  end

  it 'cancels an explicitly selected own appointment when the contact has several bookings' do
    selected = create(:scheduling_appointment, account: account, contact: contact, conversation: conversation)
    other = create(:scheduling_appointment, account: account, contact: contact, conversation: conversation)

    result = described_class.new(assistant).execute(tool_context, appointment_id: selected.id)

    expect(JSON.parse(result).fetch('appointment_id')).to eq(selected.id)
    expect(selected.reload.status).to eq('cancelled')
    expect(other.reload.status).to eq('scheduled')
  end

  it 'returns the same neutral result for foreign and absent ids without changing records' do
    other_contact = create(:contact, account: account)
    foreign = create(:scheduling_appointment, account: account, contact: other_contact)
    cross_account = create(:scheduling_appointment, account: create(:account))

    [described_class, Captain::Tools::UpdateAppointmentTool].each do |tool_class|
      arguments = tool_class == Captain::Tools::UpdateAppointmentTool ? { client_comment: 'Must not change' } : {}
      results = [foreign.id, cross_account.id, missing_id].map do |id|
        tool_class.new(assistant).execute(tool_context, appointment_id: id, **arguments)
      end
      expect(results.map { |result| JSON.parse(result) }).to all(eq(neutral_failure))
    end

    expect(foreign.reload.status).to eq('scheduled')
    expect(foreign.client_comment).not_to eq('Must not change')
    expect(cross_account.reload.status).to eq('scheduled')
  end

  it 'updates an own appointment created in a previous conversation' do
    previous_conversation = create(:conversation, account: account, contact: contact)
    appointment = create(:scheduling_appointment, account: account, contact: contact, conversation: previous_conversation)

    result = Captain::Tools::UpdateAppointmentTool.new(assistant).execute(
      tool_context, appointment_id: appointment.id, client_comment: 'New request'
    )

    expect(JSON.parse(result).fetch('appointment_id')).to eq(appointment.id)
    expect(appointment.reload.client_comment).to eq('New request')
  end

  it 'requires a task token and explicit confirmation to change one other patient appointment' do
    patient = create(:contact, account: account, name: 'Test Son')
    selected = create(:scheduling_appointment, account: account, contact: patient, client_name: 'Test Son')
    other = create(:scheduling_appointment, account: account, contact: patient)
    token = Captain::Tools::Agent::AppointmentAccess.issue(assistant: assistant, conversation: conversation, appointment: selected)
    tool = Captain::Tools::UpdateAppointmentTool.new(assistant)

    unconfirmed = JSON.parse(tool.execute(tool_context, appointment_id: selected.id,
                                                      appointment_access_token: token, client_comment: 'Family request'))
    expect(unconfirmed).to include('success' => false)
    expect(selected.reload.client_comment).not_to eq('Family request')

    confirmed = JSON.parse(tool.execute(tool_context, appointment_id: selected.id, appointment_access_token: token,
                                                    patient_confirmed: true, client_comment: 'Family request'))
    expect(confirmed).to include('success' => true, 'appointment_id' => selected.id)
    expect(selected.reload.client_comment).to eq('Family request')
    expect(other.reload.client_comment).not_to eq('Family request')
    expect(conversation.reload.contact_id).to eq(contact.id)

    stale = JSON.parse(tool.execute(tool_context, appointment_id: selected.id, appointment_access_token: token,
                                                patient_confirmed: true, client_comment: 'Stale repeat'))
    expect(stale).to eq(neutral_failure)
    expect(selected.reload.client_comment).to eq('Family request')
  end

  # Suggestion eval 27.10 (c76-1231671): the visit to cancel is a child's, booked from the parent's chat. search_appointments lists it
  # with a task token (the same appointments as list_my_appointments); with that token and the patient's confirmation it is cancelled.
  it 'cancels a linked patient appointment with the token that search_appointments lists for it and the confirmation' do
    child = create(:contact, account: account, name: 'Test Son')
    visit = create(:scheduling_appointment, account: account, contact: contact, patient_contact: child, client_name: 'Test Son')
    search_context = Struct.new(:state, :context).new({ conversation: { id: conversation.id } }, {})
    listing = JSON.parse(Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'search_appointments').execute(search_context))
    listed = listing.fetch('appointments').sole
    tool = described_class.new(assistant)

    expect(listed.fetch('appointment_id')).to eq(visit.id)
    token = listed.fetch('appointment_access_token')
    expect(JSON.parse(tool.execute(tool_context, appointment_id: visit.id, appointment_access_token: token))).to include('success' => false)
    expect(visit.reload.status).to eq('scheduled')

    confirmed = JSON.parse(tool.execute(tool_context, appointment_id: visit.id, appointment_access_token: token, patient_confirmed: true))
    expect(confirmed).to include('success' => true, 'appointment_id' => visit.id)
    expect(visit.reload.status).to eq('cancelled')
  end

  # Review of quality-fixes-1 (M3): list_my_appointments gives the token of a visit it lists for another patient, so one access rule serves
  # both lookups: the token and the confirmation of the patient.
  it 'cancels a visit that list_my_appointments lists for another patient with its token and the confirmation' do
    child = create(:contact, account: account, name: 'Test Son')
    visit = create(:scheduling_appointment, account: account, contact: contact, patient_contact: child, client_name: 'Test Son')
    listing = JSON.parse(Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'list_my_appointments').execute(
                           Struct.new(:state, :context).new({ conversation: { id: conversation.id } }, {}), status: 'scheduled'
                         ))
    token = listing.fetch('appointments').sole.fetch('appointment_access_token')
    tool = described_class.new(assistant)

    expect(JSON.parse(tool.execute(tool_context, appointment_id: visit.id))).to include('success' => false)
    expect(JSON.parse(tool.execute(tool_context, appointment_id: visit.id, appointment_access_token: token))).to include('success' => false)
    expect(visit.reload.status).to eq('scheduled')

    confirmed = JSON.parse(tool.execute(tool_context, appointment_id: visit.id, appointment_access_token: token, patient_confirmed: true))
    expect(confirmed).to include('success' => true, 'appointment_id' => visit.id)
    expect(visit.reload.status).to eq('cancelled')
  end

  it 'requires both task access and confirmation for a family appointment already linked to this chat' do
    patient = create(:contact, account: account)
    selected = create(:scheduling_appointment, account: account, contact: contact,
                                             patient_contact: patient, conversation: conversation)
    tool = described_class.new(assistant)

    expect(JSON.parse(tool.execute(tool_context, appointment_id: selected.id))).to include('success' => false)
    expect(selected.reload.status).to eq('scheduled')
    expect(JSON.parse(tool.execute(tool_context, appointment_id: selected.id, patient_confirmed: true)))
      .to include('success' => false)
    expect(selected.reload.status).to eq('scheduled')
    token = Captain::Tools::Agent::AppointmentAccess.issue(assistant: assistant, conversation: conversation, appointment: selected)
    expect(JSON.parse(tool.execute(tool_context, appointment_id: selected.id, appointment_access_token: token)))
      .to include('success' => false)
    expect(JSON.parse(tool.execute(tool_context, appointment_id: selected.id, appointment_access_token: token, patient_confirmed: true)))
      .to include('success' => true, 'appointment_id' => selected.id)
    expect(selected.reload.status).to eq('cancelled')
  end
end
