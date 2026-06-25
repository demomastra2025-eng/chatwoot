require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::SetInboxAssignmentPolicyService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    confirmation_gate = instance_double(Captain::Copilot::ToolConfirmationGate, call: nil)
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
  end

  it 'attaches an account assignment policy to an inbox' do
    inbox = create(:inbox, account: account, name: 'Support')
    policy = create(:assignment_policy, account: account, name: 'Support routing', assign_online_only: false)

    payload = JSON.parse(service.execute(inbox_id: inbox.id, assignment_policy_id: policy.id))

    expect(payload['action']).to eq('set_inbox_assignment_policy')
    expect(payload['inbox']).to include('id' => inbox.id, 'name' => 'Support')
    expect(payload['assignment_policy']).to include('id' => policy.id, 'name' => 'Support routing', 'assign_online_only' => false)
    expect(inbox.reload.assignment_policy).to eq(policy)
  end

  it 'replaces an existing inbox assignment policy' do
    inbox = create(:inbox, account: account)
    old_policy = create(:assignment_policy, account: account, name: 'Old routing')
    new_policy = create(:assignment_policy, account: account, name: 'New routing')
    create(:inbox_assignment_policy, inbox: inbox, assignment_policy: old_policy)

    service.execute(inbox_id: inbox.id, assignment_policy_id: new_policy.id)

    expect(inbox.reload.assignment_policy).to eq(new_policy)
  end

  it 'rejects inboxes and policies outside the assistant account' do
    inbox = create(:inbox, account: account)
    other_policy = create(:assignment_policy, account: create(:account))

    result = service.execute(inbox_id: inbox.id, assignment_policy_id: other_policy.id)

    expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
    expect(inbox.reload.assignment_policy).to be_nil
  end

  it 'does not mutate until the backend confirmation gate permits execution' do
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
    inbox = create(:inbox, account: account)
    policy = create(:assignment_policy, account: account)

    payload = JSON.parse(service.execute(inbox_id: inbox.id, assignment_policy_id: policy.id))

    expect(payload['message']).to include('Operator confirmation is required')
    expect(inbox.reload.assignment_policy).to be_nil
  end

  it 'enforces admin permission inside execute before mutating' do
    agent = create(:user, account: account)
    non_admin_service = described_class.new(assistant, user: agent)
    inbox = create(:inbox, account: account)
    policy = create(:assignment_policy, account: account)

    allow(non_admin_service).to receive(:active?).and_return(true)
    result = non_admin_service.execute(inbox_id: inbox.id, assignment_policy_id: policy.id)

    expect(result).to start_with('ERROR: ArgumentError: Account administrator permission is required')
    expect(inbox.reload.assignment_policy).to be_nil
  end

  it 'is active only for account administrators' do
    agent = create(:user, account: account)

    expect(service).to be_active
    expect(described_class.new(assistant, user: agent)).not_to be_active
  end
end
