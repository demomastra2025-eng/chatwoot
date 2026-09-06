require 'rails_helper'

RSpec.describe Captain::Tools::CancelAppointmentTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }

  before do
    account.enable_features!('scheduling')
  end

  it 'returns normalized cancel_appointment payload' do
    resource = create(:scheduling_resource, account: account)
    contact = create(:contact, account: account)
    scheduling_service = create(:scheduling_service, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    appointment = create(:scheduling_appointment, account: account, resource: resource, contact: contact, service: scheduling_service,
                                                  conversation_id: conversation.id)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id } })

    payload = JSON.parse(tool.perform(tool_context))

    expect(payload).to include(
      'action' => 'cancel_appointment',
      'appointment_id' => appointment.id,
      'status' => 'cancelled',
      'resource_id' => resource.id,
      'contact_id' => contact.id,
      'service_id' => scheduling_service.id,
      'starts_at' => payload.dig('appointment', 'starts_at'),
      'ends_at' => payload.dig('appointment', 'ends_at')
    )
    expect(payload['appointment']).to include('id' => appointment.id, 'status' => 'cancelled')
  end

  it 'does not cancel an imported Medelement appointment' do
    resource = create(:scheduling_resource, account: account)
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation,
      source: 'medelement',
      external_ref: 'medelement:reception:captain-cancel'
    )
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id } })

    result = tool.perform(tool_context)

    expect(result).to include('ERROR: Scheduling::Error: Imported Medelement appointments are read-only')
    expect(appointment.reload.status).to eq('scheduled')
  end

  it 'returns the exact remove command receipt for a provider-backed appointment' do
    settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true)
    create(:integrations_hook, :medelement, account: account, settings: settings)
    resource = create(:scheduling_resource, account: account, custom_attributes: {
                        'medelement_specialist_code' => 'specialist-1',
                        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
                      })
    contact = create(:contact, account: account, name: 'Aruzhan', last_name: 'Testova', phone_number: '+77011234567')
    conversation = create(:conversation, account: account, contact: contact)
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation,
      external_ref: 'medelement:reception:reception-1',
      custom_attributes: { 'medelement_reception_code' => 'reception-1', 'medelement_cabinet_code' => 'cabinet-1' }
    )
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id } })

    result = tool.perform(tool_context)
    raise result if result.start_with?('ERROR:')

    payload = JSON.parse(result)

    expect(payload.dig('provider_command_receipt', 'command')).to include(
      'operation' => 'remove_reception',
      'requested_by' => { 'type' => 'Captain::Assistant', 'id' => assistant.id }
    )
  end
end
