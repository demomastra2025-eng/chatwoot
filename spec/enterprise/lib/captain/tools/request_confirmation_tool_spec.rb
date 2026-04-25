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
    expect(payload.dig('confirmation_request', 'conversation_id')).to eq(conversation.id)
    expect(payload.dig('confirmation_request', 'subject')).to be_nil
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
end
