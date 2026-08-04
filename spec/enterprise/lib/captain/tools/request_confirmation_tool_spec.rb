require 'rails_helper'

RSpec.describe Captain::Tools::RequestConfirmationTool do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:tool) { described_class.new(assistant) }
  let(:tool_context) { Struct.new(:state).new({ conversation: { id: conversation.id } }) }

  it 'creates a standalone confirmation for the current conversation' do
    payload = JSON.parse(tool.perform(
                           tool_context,
                           title: 'Подтвердить намерение',
                           body: 'Подтверждаете?',
                           send_now: false
                         ))

    expect(payload['action']).to eq('request_confirmation')
    expect(payload['status']).to eq('ok')
    expect(payload.dig('confirmation_request', 'conversation_id')).to eq(conversation.id)
    expect(payload.dig('confirmation_request', 'subject')).to be_nil
    expect(payload['confirmation_request']).not_to have_key('token')
  end

  it 'uses current appointment context when subject_kind is appointment' do
    appointment = create(:scheduling_appointment, account: account, conversation: conversation, contact: conversation.contact)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id } })

    payload = JSON.parse(tool.perform(
                           tool_context,
                           title: 'Подтвердить прием',
                           body: 'Вы подтверждаете прием?',
                           subject_kind: 'appointment',
                           send_now: false
                         ))

    expect(payload.dig('confirmation_request', 'subject')).to include('type' => 'Scheduling::Appointment', 'id' => appointment.id)
  end

  it 'normalizes a class-style subject kind emitted by the model' do
    conversation = create(:conversation, account: account)
    tool_context.state[:conversation] = { id: conversation.id }

    payload = JSON.parse(
      tool.perform(
        tool_context,
        title: 'Confirm conversation',
        body: 'Please confirm',
        subject_kind: 'Conversation',
        send_now: false
      )
    )

    expect(payload.dig('confirmation_request', 'subject')).to include(
      'type' => 'Conversation',
      'id' => conversation.id
    )
  end

  it 'returns a partial failure with the persisted request when delivery fails' do
    delivery = instance_double(Confirmations::DeliveryService)
    allow(Confirmations::DeliveryService).to receive(:new).and_return(delivery)
    allow(delivery).to receive(:perform).and_raise(Timeout::Error, 'provider timeout')

    result = tool.perform(tool_context, title: 'Подтвердить', body: 'Подтверждаете?', send_now: true)
    normalized = Captain::ToolResult.normalize(result)
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
    expect(request.metadata).to include(
      'delivery_status' => 'unknown',
      'delivery_outcome_known' => false,
      'delivery_error_code' => 'Timeout::Error',
      'delivery_recovery_confirmation_request_id' => request.id
    )
  end
end
