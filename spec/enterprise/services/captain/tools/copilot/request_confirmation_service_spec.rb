require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::RequestConfirmationService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  it 'creates a structured standalone confirmation request without sending when send_now is false' do
    payload = JSON.parse(service.execute(
                           title: 'Подтвердить заявку',
                           body: 'Подтверждаете заявку?',
                           send_now: false,
                           expires_at: 2.hours.from_now.iso8601,
                           metadata: { purpose: 'standalone' }
                         ))

    expect(payload['action']).to eq('request_confirmation')
    expect(payload.dig('confirmation_request', 'status')).to eq('pending')
    expect(payload.dig('confirmation_request', 'subject')).to be_nil
    expect(payload.dig('confirmation_request', 'conversation_id')).to eq(conversation.id)
    expect(payload['delivery']).to be_nil
    expect(ConfirmationRequest.last.metadata).to include('purpose' => 'standalone')
  end

  it 'creates a subject-bound appointment confirmation and sends a channel-aware message by default' do
    appointment = create(:scheduling_appointment, account: account, conversation: conversation, contact: conversation.contact)

    payload = JSON.parse(service.execute(
                           title: 'Подтвердить прием',
                           body: 'Вы подтверждаете прием?',
                           subject_type: 'Scheduling::Appointment',
                           subject_id: appointment.id
                         ))

    request = ConfirmationRequest.last
    expect(payload['action']).to eq('request_confirmation')
    expect(payload.dig('confirmation_request', 'subject')).to include('type' => 'Scheduling::Appointment', 'id' => appointment.id)
    expect(payload.dig('delivery', 'message_id')).to eq(request.delivery_message_id)
    expect(request.subject).to eq(appointment)
  end
end
