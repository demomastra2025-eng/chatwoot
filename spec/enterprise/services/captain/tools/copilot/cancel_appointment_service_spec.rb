require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::CancelAppointmentService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user, assistant: assistant) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation, copilot_thread: copilot_thread) }

  before do
    account.enable_features!('scheduling')
  end

  it 'returns normalized cancelled appointment payload wrapper' do
    resource = create(:scheduling_resource, account: account)
    scheduling_service = create(:scheduling_service, account: account)
    appointment = create(:scheduling_appointment, account: account, resource: resource, contact: contact, service: scheduling_service,
                                                  conversation_id: conversation.id)

    payload = JSON.parse(execute_confirmed)

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
    expect(payload['appointment']).to include(
      'id' => appointment.id,
      'status' => 'cancelled'
    )
  end

  def execute_confirmed(**arguments)
    first_result = service.execute(**arguments)
    first_payload = JSON.parse(first_result)
    return first_result unless first_payload.dig('data', 'confirmation_required')

    confirmation_token = copilot_thread.copilot_messages.assistant_thinking.last.message.dig('confirmation_gate', 'confirmation_token')

    create(
      :captain_copilot_message,
      account: account,
      copilot_thread: copilot_thread,
      message_type: 'user',
      message: { 'content' => "Подтверждаю #{confirmation_token}" }
    )

    service.execute(**arguments)
  end
end
