require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::AddInboxMembersService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    confirmation_gate = instance_double(Captain::Copilot::ToolConfirmationGate, call: nil)
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
  end

  it 'adds account users to an inbox' do
    inbox = create(:inbox, account: account)
    member = create(:user, account: account, name: 'Operator One')

    payload = JSON.parse(service.execute(inbox_id: inbox.id, user_ids: member.id.to_s))

    expect(payload['action']).to eq('add_inbox_members')
    expect(payload['added_user_ids']).to eq([member.id])
    expect(inbox.reload.members).to include(member)
  end

  it 'rejects users outside the assistant account' do
    inbox = create(:inbox, account: account)
    other_user = create(:user, account: create(:account))

    result = service.execute(inbox_id: inbox.id, user_ids: other_user.id.to_s)

    expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
    expect(inbox.reload.members).to be_empty
  end

  it 'does not mutate until the backend confirmation gate permits execution' do
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
    inbox = create(:inbox, account: account)
    member = create(:user, account: account)

    payload = JSON.parse(service.execute(inbox_id: inbox.id, user_ids: member.id.to_s))

    expect(payload['message']).to include('Operator confirmation is required')
    expect(inbox.reload.members).to be_empty
  end
end
