require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::CancelAppointmentService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  before do
    account.enable_features!('scheduling')
  end

  it 'returns normalized cancelled appointment payload wrapper' do
    resource = create(:scheduling_resource, account: account)
    scheduling_service = create(:scheduling_service, account: account)
    appointment = create(:scheduling_appointment, account: account, resource: resource, contact: contact, service: scheduling_service,
                                                  conversation_id: conversation.id)

    payload = JSON.parse(service.execute)

    expect(payload).to include('action' => 'cancel_appointment')
    expect(payload['appointment']).to include(
      'id' => appointment.id,
      'status' => 'cancelled'
    )
  end
end
