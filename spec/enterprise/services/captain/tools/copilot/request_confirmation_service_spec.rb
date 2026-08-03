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

  it 'returns an unknown delivery outcome with a recovery anchor when message creation raises' do
    delivery = instance_double(Confirmations::DeliveryService)
    allow(Confirmations::DeliveryService).to receive(:new).and_return(delivery)
    allow(delivery).to receive(:perform).and_raise(Timeout::Error, 'provider timeout')

    normalized = Captain::ToolResult.normalize(
      service.execute(title: 'Подтвердить', body: 'Подтверждаете?', send_now: true)
    )
    request = ConfirmationRequest.last

    expect(normalized).to include(success: false, retryable: false)
    expect(normalized[:data]).to include(
      status: 'partial',
      confirmation_request: include(id: request.id),
      delivery: include(status: 'unknown', delivery_outcome_known: false, error_code: 'Timeout::Error')
    )
    expect(normalized[:audit]).to include(
      failure_reason: 'delivery_outcome_unknown',
      confirmation_request_id: request.id,
      automatic_retry_blocked: true
    )
  end
end
