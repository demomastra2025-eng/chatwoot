require 'rails_helper'

RSpec.describe Crm::Tasks::RealtimeRecipients do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, :administrator, account: account) }
  let(:assignee) { create(:user, account: account, role: :agent) }
  let(:other_agent) { create(:user, account: account, role: :agent) }

  before do
    administrator
    assignee
    other_agent
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end

  it 'returns only users who can currently view the task' do
    task = create(:crm_task, account: account, assignee: assignee)

    expect(described_class.new(account: account, task: task).tokens).to contain_exactly(
      administrator.pubsub_token,
      assignee.pubsub_token
    )
  end

  it 'includes old and new recipients after reassignment' do
    task = create(:crm_task, account: account, assignee: other_agent)

    expect(
      described_class.new(
        account: account,
        task: task,
        changes: { assignee_id: [assignee.id, other_agent.id] }
      ).tokens
    ).to contain_exactly(administrator.pubsub_token, assignee.pubsub_token, other_agent.pubsub_token)
  end

  it 'includes same-team viewers and excludes cross-account users' do
    team = create(:team, account: account)
    create(:team_member, team: team, user: assignee)
    create(:team_member, team: team, user: other_agent)
    outside_account = create(:account)
    outside_user = create(:user, account: outside_account, role: :administrator)
    task = create(:crm_task, account: account, assignee: assignee, team: team)
    employee_role = assignee.account_users.find_by!(account: account).access_role
    employee_role.grants.find_by!(resource: 'tasks', capability: 'view').update!(access_scope: 'team')

    expect(described_class.new(account: account, task: task).tokens).to contain_exactly(
      administrator.pubsub_token,
      assignee.pubsub_token,
      other_agent.pubsub_token
    )
    expect(described_class.new(account: account, task: task).tokens).not_to include(outside_user.pubsub_token)
  end

  it 'stops broadcasting to employees after task view access is revoked' do
    task = create(:crm_task, account: account, assignee: assignee)
    employee_role = assignee.account_users.find_by!(account: account).access_role
    employee_role.grants.find_by!(resource: 'tasks', capability: 'view').update!(access_scope: 'none')

    expect(described_class.new(account: account, task: task).tokens).to contain_exactly(administrator.pubsub_token)
  end
end
