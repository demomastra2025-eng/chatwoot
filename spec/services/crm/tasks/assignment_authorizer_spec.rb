require 'rails_helper'

RSpec.describe Crm::Tasks::AssignmentAuthorizer do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account, role: :agent) }
  let(:other_agent) { create(:user, account: account, role: :agent) }

  it 'allows self assignment and rejects another assignee for own scope' do
    enforce_access_control!

    expect(described_class.call(account: account, actor: actor, assignee: actor, team: nil)).to be(true)
    expect do
      described_class.call(account: account, actor: actor, assignee: other_agent, team: nil)
    end.to raise_error(Crm::Error, 'Task assignee or team is outside the assignment scope')
  end

  it 'allows team assignment only to a member of the actor team' do
    enforce_access_control!
    actor.account_users.find_by!(account: account).access_role.grants.find_by!(resource: 'tasks', capability: 'assign')
         .update!(access_scope: 'team')
    team = create(:team, account: account)
    create(:team_member, team: team, user: actor)
    create(:team_member, team: team, user: other_agent)

    expect(described_class.call(account: account, actor: actor, assignee: other_agent, team: team)).to be(true)
  end

  it 'rejects inconsistent assignee and team even for all scope' do
    enforce_access_control!
    actor.account_users.find_by!(account: account).access_role.grants.find_by!(resource: 'tasks', capability: 'assign')
         .update!(access_scope: 'all')
    team = create(:team, account: account)

    expect do
      described_class.call(account: account, actor: actor, assignee: other_agent, team: team)
    end.to raise_error(Crm::Error, 'Task assignee or team is outside the assignment scope')
  end

  def enforce_access_control!
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end
end
