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

  it 'rejects direct customer-AI creation before changing an appointment' do
    resource = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 30)
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    scheduling_service = create(:scheduling_service, account: account, duration_min: 30)
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_service_price, account: account, service: scheduling_service, resource: resource, active: true, price: 20_000)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: contact.id } })

    expect do
      expect(tool.perform(tool_context, resource_id: resource.id, service_id: scheduling_service.id,
                                        starts_at: Time.zone.parse('2026-04-20 09:00:00 +0500').iso8601,
                                        duration_min: 30, custom_attributes: { source: 'agent' }))
        .to include('ERROR: Pundit::NotAuthorizedError')
    end.not_to change(account.scheduling_appointments, :count)
  end

  it 'exposes custom_attributes as an object parameter' do
    expect(described_class.parameters[:custom_attributes].type).to eq('object')
  end

  it 'forbids claiming a provider-backed booking before provider confirmation' do
    expect(tool.description).to include('pending_provider_confirmation', 'provider_confirmed is true')
  end

  it 'does not mint a provider receipt for a direct customer-AI create' do
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
    expect do
      expect(tool.perform(tool_context, **arguments)).to include('ERROR: Pundit::NotAuthorizedError')
    end.not_to change(Integrations::Medelement::ProviderCommand, :count)
    expect(account.scheduling_appointments.count).to eq(0)
  end
end
