require 'rails_helper'

RSpec.describe Captain::Tools::Account::CancelAppointmentService do
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
    expect(payload['appointment']).not_to include('payment_status', 'prepaid_amount', 'settlement_amount', 'payments', 'expense')
  end

  it 'cancels the explicitly selected appointment when the conversation has multiple appointments' do
    resource = create(:scheduling_resource, account: account)
    selected = create(:scheduling_appointment, account: account, resource: resource, contact: contact, conversation: conversation)
    other = create(:scheduling_appointment, account: account, resource: resource, contact: contact, conversation: conversation)

    payload = JSON.parse(execute_confirmed(appointment_id: selected.id))

    expect(payload).to include('appointment_id' => selected.id, 'status' => 'cancelled')
    expect(other.reload.status).to eq('scheduled')
  end

  it 'returns the remove command receipt for a confirmed employee cancellation' do
    settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true)
    create(:integrations_hook, :medelement, account: account, settings: settings)
    resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: {
        'medelement_specialist_code' => 'specialist-1',
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
      }
    )
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation,
      external_ref: 'medelement:reception:reception-1',
      custom_attributes: {
        'medelement_reception_code' => 'reception-1',
        'medelement_cabinet_code' => 'cabinet-1'
      }
    )

    payload = JSON.parse(execute_confirmed(appointment_id: appointment.id))
    receipt = payload.fetch('provider_command_receipt')
    expect(receipt).to include('appointment_id' => appointment.id, 'expected_operation' => 'remove_reception', 'linked' => true)
    expect(receipt.fetch('command')).to include(
      'operation' => 'remove_reception', 'requested_by' => { 'type' => 'User', 'id' => user.id }
    )
    expect(Integrations::Medelement::ProviderCommand.find(receipt.dig('command', 'id')).appointment_id).to eq(appointment.id)
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
