require 'rails_helper'

RSpec.describe Crm::Deals::AssignmentAuthorizer do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account, role: :agent) }
  let(:other_agent) { create(:user, account: account, role: :agent) }

  it 'allows an employee to retain self ownership and rejects another owner' do
    enforce_access_control!

    expect(described_class.call(account: account, actor: actor, owner: actor, team: nil)).to be(true)
    expect do
      described_class.call(account: account, actor: actor, owner: other_agent, team: nil)
    end.to raise_error(Crm::Error, 'Deal owner or team is outside the assignment scope')
  end

  it 'allows a team-scoped actor to assign a member within an explicit member team' do
    custom_role = create(:custom_role, account: account, permissions: %w[crm_deal_manage])
    actor.account_users.find_by!(account: account).update!(custom_role: custom_role)
    enforce_access_control!
    actor.account_users.find_by!(account: account).access_role.grants.find_by!(resource: 'deals', capability: 'assign')
         .update!(access_scope: 'team')
    team = create(:team, account: account)
    create(:team_member, team: team, user: actor)
    create(:team_member, team: team, user: other_agent)

    expect(described_class.call(account: account, actor: actor, owner: other_agent, team: team)).to be(true)
  end

  it 'preserves system writes without an actor' do
    enforce_access_control!

    expect(described_class.call(account: account, actor: nil, owner: other_agent, team: nil)).to be(true)
  end

  it 'fails closed from a stale account object when the actor has no account membership' do
    stale_account = Account.find(account.id)
    AccessControl::SystemRoleBootstrapper.call(account: account)
    AccessControl::ModeTransition.call(account: Account.find(account.id), to: :shadow)
    AccessControl::ModeTransition.call(account: Account.find(account.id), to: :enforced)
    outsider = create(:user)

    expect do
      described_class.call(account: stale_account, actor: outsider, owner: nil, team: nil)
    end.to raise_error(Crm::Error, 'Deal owner or team is outside the assignment scope')
  end

  def enforce_access_control!
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end
end
