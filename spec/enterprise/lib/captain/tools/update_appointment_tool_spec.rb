require 'rails_helper'

RSpec.describe Captain::Tools::UpdateAppointmentTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }

  before do
    account.enable_features!('scheduling')
  end

  def stub_provider_availability
    result = Integrations::Medelement::ResourceAvailabilityService::Result.new(
      status: 'fresh', checked_at: Time.current, slots: [{}], reason: nil
    )
    service = instance_double(Integrations::Medelement::ResourceAvailabilityService, perform: result)
    allow(Integrations::Medelement::ResourceAvailabilityService).to receive(:new).and_return(service)
  end

  it 'returns normalized update_appointment payload' do
    resource = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 30)
    new_resource = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 20)
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    scheduling_service = create(:scheduling_service, account: account, duration_min: 30)
    new_service = create(:scheduling_service, account: account, duration_min: 20)
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_work_rule, resource: new_resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_service_price, account: account, service: scheduling_service, resource: resource, active: true, price: 20_000)
    create(:scheduling_service_price, account: account, service: new_service, resource: new_resource, active: true, price: 10_000)
    appointment = create(:scheduling_appointment, account: account, resource: resource, contact: contact, service: scheduling_service,
                                                  conversation_id: conversation.id)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id }, contact: { id: contact.id } })

    payload = JSON.parse(tool.perform(tool_context, resource_id: new_resource.id, service_id: new_service.id,
                                                    starts_at: Time.zone.parse('2026-04-20 11:00:00 +0500').iso8601,
                                                    custom_attributes: { source: 'agent' }))

    expect(payload).to include(
      'action' => 'update_appointment',
      'appointment_id' => appointment.id,
      'status' => payload.dig('appointment', 'status'),
      'resource_id' => new_resource.id,
      'contact_id' => contact.id,
      'service_id' => new_service.id,
      'starts_at' => payload.dig('appointment', 'starts_at'),
      'ends_at' => payload.dig('appointment', 'ends_at')
    )
    expect(payload['appointment']).to include('id' => appointment.id, 'resource_id' => new_resource.id, 'service_id' => new_service.id)
    expect(payload.dig('appointment', 'custom_attributes')).to include('source' => 'agent')
  end

  it 'exposes custom_attributes as an object parameter' do
    expect(described_class.parameters[:custom_attributes].type).to eq('object')
  end

  it 'updates the explicitly selected appointment when the conversation has multiple appointments' do
    resource = create(:scheduling_resource, account: account)
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    selected = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation,
      starts_at: 2.days.from_now
    )
    other = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation,
      starts_at: 3.days.from_now
    )
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: selected.id } })

    result = tool.perform(tool_context, appointment_id: selected.id, client_comment: 'Selected appointment')

    expect(result).not_to start_with('ERROR:')
    expect(selected.reload.client_comment).to eq('Selected appointment')
    expect(other.reload.client_comment).to be_nil
  end

  it 'does not fall back when the explicit appointment belongs to another conversation' do
    resource = create(:scheduling_resource, account: account)
    conversation = create(:conversation, account: account)
    other_conversation = create(:conversation, account: account)
    linked = create(:scheduling_appointment, account: account, resource: resource, conversation: conversation)
    unauthorized = create(:scheduling_appointment, account: account, resource: resource, conversation: other_conversation)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

    result = tool.perform(tool_context, appointment_id: unauthorized.id, client_comment: 'Must not be applied')

    expect(result).to include('ERROR: ArgumentError: Appointment is not available for the current conversation')
    expect(linked.reload.client_comment).to be_nil
    expect(unauthorized.reload.client_comment).to be_nil
  end

  it 'rejects an explicit appointment from another account before mutation' do
    other_account = create(:account)
    resource = create(:scheduling_resource, account: account)
    foreign_resource = create(:scheduling_resource, account: other_account)
    conversation = create(:conversation, account: account)
    linked = create(:scheduling_appointment, account: account, resource: resource, conversation: conversation)
    foreign = create(:scheduling_appointment, account: other_account, resource: foreign_resource)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

    result = tool.perform(tool_context, appointment_id: foreign.id, client_comment: 'Must not be applied')

    expect(result).to include('ERROR: ArgumentError: Appointment is not available for the current conversation')
    expect(linked.reload.client_comment).to be_nil
    expect(foreign.reload.client_comment).to be_nil
  end

  it 'rejects explicitly provided invalid appointment IDs without falling back to the only appointment' do
    resource = create(:scheduling_resource, account: account)
    conversation = create(:conversation, account: account)
    appointment = create(:scheduling_appointment, account: account, resource: resource, conversation: conversation)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })

    ['', false, 0, -1, 'invalid', '1.5'].each do |appointment_id|
      result = tool.perform(tool_context, appointment_id: appointment_id, client_comment: 'Must not be applied')

      expect(result).to include('ERROR: ArgumentError: appointment_id is required')
    end

    expect(appointment.reload.client_comment).to be_nil
  end

  it 'requires an appointment ID instead of selecting the latest appointment when the conversation is ambiguous' do
    resource = create(:scheduling_resource, account: account)
    conversation = create(:conversation, account: account)
    appointments = create_list(:scheduling_appointment, 2, account: account, resource: resource, conversation: conversation)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id } })
    create(:integrations_hook, :medelement, account: account)
    resource.update!(custom_attributes: { 'medelement_specialist_code' => 'specialist-1' })

    result = nil
    expect do
      result = tool.perform(tool_context, client_comment: 'Must not be applied')
    end.not_to change(Integrations::Medelement::ProviderCommand, :count)

    expect(result).to include('ERROR: ArgumentError: appointment_id is required when the conversation has multiple appointments')
    expect(appointments.map { |appointment| appointment.reload.client_comment }).to all(be_nil)
  end

  it 'does not update an imported Medelement appointment' do
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
      external_ref: 'medelement:reception:captain-update'
    )
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id } })

    result = tool.perform(tool_context, client_comment: 'Changed by Captain')

    expect(result).to include('ERROR: Scheduling::Error: Imported Medelement appointments are read-only')
    expect(appointment.reload.client_comment).to be_nil
  end

  it 'returns the exact move command receipt for a provider-backed appointment' do
    stub_provider_availability
    settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true)
    create(:integrations_hook, :medelement, account: account, settings: settings)
    resource = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', custom_attributes: {
                        'medelement_specialist_code' => 'specialist-1',
                        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
                      })
    contact = create(
      :contact,
      account: account,
      name: 'Aruzhan',
      last_name: 'Testova',
      phone_number: '+77011234567',
      custom_attributes: { 'medelement_patient_code' => 'patient-1' }
    )
    conversation = create(:conversation, account: account, contact: contact)
    service = create(
      :scheduling_service,
      account: account,
      duration_min: 30,
      custom_attributes: { 'medelement_nomenclature_code' => 'service-1' }
    )
    create(:scheduling_service_price, account: account, service: service, resource: resource, active: true)
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation,
      service: service,
      external_ref: 'medelement:reception:reception-1',
      starts_at: Time.zone.parse('2026-04-20 09:00:00 +0500'),
      ends_at: Time.zone.parse('2026-04-20 09:30:00 +0500'),
      custom_attributes: { 'medelement_reception_code' => 'reception-1', 'medelement_cabinet_code' => 'cabinet-1' }
    )
    other = create_other_appointment(account: account, resource: resource, contact: contact, conversation: conversation, service: service)
    other_starts_at = other.starts_at
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id } })

    moved_starts_at = Time.zone.parse('2026-04-20 10:00:00 +0500').iso8601
    result = tool.perform(tool_context, appointment_id: appointment.id, starts_at: moved_starts_at)
    raise result if result.start_with?('ERROR:')

    payload = JSON.parse(result)

    command_payload = payload.dig('provider_command_receipt', 'command')
    expect(command_payload).to include(
      'operation' => 'move_reception',
      'requested_by' => { 'type' => 'Captain::Assistant', 'id' => assistant.id }
    )
    expect(Integrations::Medelement::ProviderCommand.find(command_payload.fetch('id')).appointment_id).to eq(appointment.id)
    expect(other.reload.starts_at).to eq(other_starts_at)
  end

  def create_other_appointment(account:, resource:, contact:, conversation:, service:)
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation,
      service: service,
      starts_at: Time.zone.parse('2026-04-27 09:00:00 +0500'),
      ends_at: Time.zone.parse('2026-04-27 09:30:00 +0500')
    )
  end
end
