require 'rails_helper'

RSpec.describe Captain::Tools::Account::RemoveInboxMembersService do
  let(:account) { create(:account) }
  let!(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    confirmation_gate = instance_double(Captain::Tools::ToolConfirmationGate, call: nil)
    allow(Captain::Tools::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
  end

  it 'retains workspace members and reports that no users were removed' do
    inbox = create(:inbox, account: account)
    member = create(:user, account: account, name: 'Operator One')
    other_member = create(:user, account: account, name: 'Operator Two')

    payload = JSON.parse(service.execute(inbox_id: inbox.id, user_ids: member.id.to_s))

    expect(payload['action']).to eq('remove_inbox_members')
    expect(payload['removed_user_ids']).to be_empty
    expect(inbox.reload.members).to contain_exactly(user, member, other_member)
  end

  it 'rejects users outside the assistant account' do
    inbox = create(:inbox, account: account)
    member = create(:user, account: account)
    other_user = create(:user, account: create(:account))
    create(:inbox_member, inbox: inbox, user: member)
    existing_member_ids = inbox.inbox_members.ids

    result = service.execute(inbox_id: inbox.id, user_ids: other_user.id.to_s)

    expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
    expect(inbox.reload.inbox_members.ids).to match_array(existing_member_ids)
  end

  it 'does not mutate until the backend confirmation gate permits execution' do
    allow(Captain::Tools::ToolConfirmationGate).to receive(:new).and_call_original
    inbox = create(:inbox, account: account)
    member = create(:user, account: account)
    create(:inbox_member, inbox: inbox, user: member)
    existing_member_ids = inbox.inbox_members.ids

    payload = JSON.parse(service.execute(inbox_id: inbox.id, user_ids: member.id.to_s))

    expect(payload['message']).to include('Operator confirmation is required')
    expect(inbox.reload.inbox_members.ids).to match_array(existing_member_ids)
  end

  it 'enforces admin permission inside execute before mutating inbox members' do
    agent = create(:user, account: account)
    non_admin_service = described_class.new(assistant, user: agent)
    inbox = create(:inbox, account: account)
    member = create(:user, account: account)
    create(:inbox_member, inbox: inbox, user: member)
    existing_member_ids = inbox.inbox_members.ids

    allow(non_admin_service).to receive(:active?).and_return(true)
    result = non_admin_service.execute(inbox_id: inbox.id, user_ids: member.id.to_s)

    expect(result).to start_with('ERROR: ArgumentError: Account administrator permission is required')
    expect(inbox.reload.inbox_members.ids).to match_array(existing_member_ids)
  end
end
