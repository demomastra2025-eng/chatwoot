require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::RemoveInboxMembersService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    confirmation_gate = instance_double(Captain::Copilot::ToolConfirmationGate, call: nil)
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
  end

  it 'removes account users from an inbox' do
    inbox = create(:inbox, account: account)
    member = create(:user, account: account, name: 'Operator One')
    other_member = create(:user, account: account, name: 'Operator Two')
    create(:inbox_member, inbox: inbox, user: member)
    create(:inbox_member, inbox: inbox, user: other_member)

    payload = JSON.parse(service.execute(inbox_id: inbox.id, user_ids: member.id.to_s))

    expect(payload['action']).to eq('remove_inbox_members')
    expect(payload['removed_user_ids']).to eq([member.id])
    expect(inbox.reload.members).to contain_exactly(other_member)
  end

  it 'rejects users outside the assistant account' do
    inbox = create(:inbox, account: account)
    member = create(:user, account: account)
    other_user = create(:user, account: create(:account))
    create(:inbox_member, inbox: inbox, user: member)

    result = service.execute(inbox_id: inbox.id, user_ids: other_user.id.to_s)

    expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
    expect(inbox.reload.members).to contain_exactly(member)
  end

  it 'does not mutate until the backend confirmation gate permits execution' do
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
    inbox = create(:inbox, account: account)
    member = create(:user, account: account)
    create(:inbox_member, inbox: inbox, user: member)

    payload = JSON.parse(service.execute(inbox_id: inbox.id, user_ids: member.id.to_s))

    expect(payload['message']).to include('Operator confirmation is required')
    expect(inbox.reload.members).to contain_exactly(member)
  end

  it 'enforces admin permission inside execute before mutating inbox members' do
    agent = create(:user, account: account)
    non_admin_service = described_class.new(assistant, user: agent)
    inbox = create(:inbox, account: account)
    member = create(:user, account: account)
    create(:inbox_member, inbox: inbox, user: member)

    allow(non_admin_service).to receive(:active?).and_return(true)
    result = non_admin_service.execute(inbox_id: inbox.id, user_ids: member.id.to_s)

    expect(result).to start_with('ERROR: ArgumentError: Account administrator permission is required')
    expect(inbox.reload.members).to contain_exactly(member)
  end
end
