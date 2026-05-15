require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::UpdateInboxSettingsService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    confirmation_gate = instance_double(Captain::Copilot::ToolConfirmationGate, call: nil)
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
  end

  it 'updates safe inbox settings inside the assistant account' do
    inbox = create(:inbox, account: account, name: 'Old', timezone: 'UTC')

    payload = JSON.parse(service.execute(
                           inbox_id: inbox.id,
                           name: 'New Support',
                           timezone: 'Asia/Almaty',
                           enable_auto_assignment: false,
                           working_hours_enabled: true,
                           out_of_office_message: 'We are closed',
                           allow_messages_after_resolved: false
                         ))

    expect(payload['action']).to eq('update_inbox_settings')
    expect(payload['updated_fields']).to include(
      'name', 'timezone', 'enable_auto_assignment', 'working_hours_enabled', 'out_of_office_message', 'allow_messages_after_resolved'
    )
    expect(inbox.reload).to have_attributes(
      name: 'New Support',
      timezone: 'Asia/Almaty',
      enable_auto_assignment: false,
      working_hours_enabled: true,
      out_of_office_message: 'We are closed',
      allow_messages_after_resolved: false
    )
  end

  it 'rejects inboxes outside the assistant account' do
    other_inbox = create(:inbox, account: create(:account))

    result = service.execute(inbox_id: other_inbox.id, name: 'Nope')

    expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
  end

  it 'does not mutate until the backend confirmation gate permits execution' do
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
    inbox = create(:inbox, account: account, name: 'Old')

    payload = JSON.parse(service.execute(inbox_id: inbox.id, name: 'New'))

    expect(payload['message']).to include('Operator confirmation is required')
    expect(inbox.reload.name).to eq('Old')
  end
end
