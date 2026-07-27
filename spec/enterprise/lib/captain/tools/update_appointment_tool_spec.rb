require 'rails_helper'

RSpec.describe Captain::Tools::UpdateAppointmentTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }

  before do
    account.enable_features!('scheduling')
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
end
