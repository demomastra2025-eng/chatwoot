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
    expect(payload['appointment']).not_to include('payment_status', 'prepaid_amount', 'settlement_amount', 'payments', 'expense')
  end

  it 're-reads the explicitly selected cancelled appointment without cancelling another active appointment' do
    resource = create(:scheduling_resource, account: account)
    conversation = create(:conversation, account: account)
    selected = create(:scheduling_appointment, account: account, resource: resource, conversation: conversation, status: 'cancelled')
    other = create(:scheduling_appointment, account: account, resource: resource, conversation: conversation, status: 'scheduled')
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

    payload = JSON.parse(tool.perform(tool_context, appointment_id: selected.id))

    expect(payload).to include('appointment_id' => selected.id, 'status' => 'cancelled')
    expect(other.reload.status).to eq('scheduled')
  end

  it 'does not cancel any appointment when an explicit appointment ID is unavailable' do
    resource = create(:scheduling_resource, account: account)
    conversation = create(:conversation, account: account)
    appointment = create(:scheduling_appointment, account: account, resource: resource, conversation: conversation)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

    result = tool.perform(tool_context, appointment_id: appointment.id + 1_000_000)

    expect(result).to include('ERROR: ArgumentError: Appointment is not available for the current conversation')
    expect(appointment.reload.status).to eq('scheduled')
  end

  it 'requires an appointment ID when the conversation has multiple appointments' do
    resource = create(:scheduling_resource, account: account)
    conversation = create(:conversation, account: account)
    appointments = create_list(:scheduling_appointment, 2, account: account, resource: resource, conversation: conversation)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

    result = tool.perform(tool_context)

    expect(result).to include('ERROR: ArgumentError: appointment_id is required when the conversation has multiple appointments')
    expect(appointments.map { |appointment| appointment.reload.status }).to all(eq('scheduled'))
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
    other = create(:scheduling_appointment, account: account, resource: resource, contact: contact, conversation: conversation)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id } })

    result = tool.perform(tool_context, appointment_id: appointment.id)
    raise result if result.start_with?('ERROR:')

    payload = JSON.parse(result)

    command_payload = payload.dig('provider_command_receipt', 'command')
    expect(command_payload).to include(
      'operation' => 'remove_reception',
      'requested_by' => { 'type' => 'Captain::Assistant', 'id' => assistant.id }
    )
    expect(Integrations::Medelement::ProviderCommand.find(command_payload.fetch('id')).appointment_id).to eq(appointment.id)
    expect(other.reload.status).to eq('scheduled')
  end
end
