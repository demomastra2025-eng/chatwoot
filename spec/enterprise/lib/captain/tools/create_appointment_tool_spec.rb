require 'rails_helper'

RSpec.describe Captain::Tools::CreateAppointmentTool, type: :model do
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

  it 'returns normalized create_appointment payload' do
    resource = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 30)
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    scheduling_service = create(:scheduling_service, account: account, duration_min: 30)
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_service_price, account: account, service: scheduling_service, resource: resource, active: true, price: 20_000)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: contact.id } })

    payload = JSON.parse(tool.perform(tool_context, resource_id: resource.id, service_id: scheduling_service.id,
                                                    starts_at: Time.zone.parse('2026-04-20 09:00:00 +0500').iso8601,
                                                    duration_min: 30, custom_attributes: { source: 'agent' }))

    expect(payload).to include(
      'action' => 'create_appointment',
      'appointment_id' => payload.dig('appointment', 'id'),
      'status' => payload.dig('appointment', 'status'),
      'resource_id' => resource.id,
      'contact_id' => contact.id,
      'service_id' => scheduling_service.id,
      'starts_at' => payload.dig('appointment', 'starts_at'),
      'ends_at' => payload.dig('appointment', 'ends_at')
    )
    expect(payload['appointment']).to include('resource_id' => resource.id, 'contact_id' => contact.id, 'service_id' => scheduling_service.id)
    expect(payload.dig('appointment', 'custom_attributes')).to include('source' => 'agent')
  end

  it 'exposes custom_attributes as an object parameter' do
    expect(described_class.parameters[:custom_attributes].type).to eq('object')
  end

  it 'forbids claiming a provider-backed booking before provider confirmation' do
    expect(tool.description).to include('pending_provider_confirmation', 'provider_confirmed is true')
  end

  it 'returns the exact provider command receipt with the Captain actor descriptor' do
    stub_provider_availability
    hook_settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true)
    create(:integrations_hook, :medelement, account: account, settings: hook_settings)
    resource = create(
      :scheduling_resource,
      account: account,
      timezone: 'Asia/Almaty',
      slot_duration_min: 30,
      custom_attributes: {
        'medelement_specialist_code' => 'specialist-1',
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
      }
    )
    contact = create(:contact, account: account, name: 'Aruzhan', last_name: 'Testova', phone_number: '+77011234567')
    conversation = create(:conversation, account: account, contact: contact)
    scheduling_service = create(
      :scheduling_service,
      account: account,
      duration_min: 30,
      custom_attributes: { 'medelement_nomenclature_code' => 'service-1' }
    )
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_service_price, account: account, service: scheduling_service, resource: resource, active: true, price: 20_000)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: contact.id } })

    arguments = {
      resource_id: resource.id,
      service_id: scheduling_service.id,
      starts_at: Time.zone.parse('2026-04-20 09:00:00 +0500').iso8601,
      duration_min: 30,
      custom_attributes: { medelement_cabinet_code: 'cabinet-1' }
    }
    payload = JSON.parse(tool.perform(tool_context, **arguments))

    command_id = payload.dig('provider_command_receipt', 'command', 'id')
    command = Integrations::Medelement::ProviderCommand.find(command_id)
    appointment = account.scheduling_appointments.find(payload.fetch('appointment_id'))
    allow(Captain::ToolExecutionIdempotency).to receive(:fetch_record).and_return(appointment.reload)
    replay_payload = JSON.parse(tool.perform(tool_context, **arguments))
    expect(payload.fetch('provider_command_receipt')).to include(
      'appointment_id' => payload.fetch('appointment_id'),
      'expected_operation' => 'create_reception',
      'linked' => true
    )
    expect(payload.dig('provider_command_receipt', 'command')).to include(
      'operation' => 'create_reception',
      'requested_by' => { 'type' => 'Captain::Assistant', 'id' => assistant.id }
    )
    expect(replay_payload.fetch('provider_command_receipt')).to eq(payload.fetch('provider_command_receipt'))
    expect(Integrations::Medelement::ProviderCommand.where(account_id: account.id, operation: 'create_reception').count).to eq(1)
    expect(command.request_snapshot.fetch('actor')).to eq('type' => 'Captain::Assistant', 'id' => assistant.id)
  end
end
