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
end
