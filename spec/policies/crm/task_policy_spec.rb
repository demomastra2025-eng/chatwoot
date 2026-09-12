# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Crm::TaskPolicy, type: :policy do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account) }
  let(:administrator) { create(:user, :administrator, account: account) }
  let(:task) { create(:crm_task, account: account) }

  let(:agent_context) { { user: agent, account: account, account_user: agent.account_users.find_by!(account: account) } }
  let(:administrator_context) { { user: administrator, account: account, account_user: administrator.account_users.find_by!(account: account) } }

  it 'allows plain agents to use task runtime actions' do
    policy = described_class.new(agent_context, task)

    aggregate_failures do
      expect(policy.index?).to be(true)
      expect(policy.show?).to be(true)
      expect(policy.timeline?).to be(true)
      expect(policy.create?).to be(true)
      expect(policy.update?).to be(true)
      expect(policy.change_status?).to be(true)
      expect(policy.archive?).to be(true)
      expect(policy.unarchive?).to be(true)
    end
  end

  it 'allows administrators to use task runtime actions' do
    policy = described_class.new(administrator_context, task)

    aggregate_failures do
      expect(policy.index?).to be(true)
      expect(policy.show?).to be(true)
      expect(policy.timeline?).to be(true)
      expect(policy.create?).to be(true)
      expect(policy.update?).to be(true)
      expect(policy.change_status?).to be(true)
      expect(policy.archive?).to be(true)
      expect(policy.unarchive?).to be(true)
    end
  end

  it 'enforces own, team, and all task scopes from one relation' do
    teammate = create(:user, account: account)
    outsider = create(:user, account: account)
    team = create(:team, account: account)
    create(:team_member, team: team, user: agent)
    create(:team_member, team: team, user: teammate)
    own_task = create(:crm_task, account: account, assignee: agent)
    team_task = create(:crm_task, account: account, assignee: teammate, team: team)
    outside_task = create(:crm_task, account: account, assignee: outsider)
    enforce_access_roles!
    grant = agent.account_users.find_by!(account: account).access_role.grants.find_by!(resource: 'tasks', capability: 'view')

    expect(described_class::Scope.new(agent_context, account.crm_tasks).resolve).to contain_exactly(own_task)
    expect(described_class.new(agent_context, team_task).show?).to be(false)

    grant.update!(access_scope: 'team')
    expect(described_class::Scope.new(agent_context, account.crm_tasks).resolve).to contain_exactly(own_task, team_task)

    grant.update!(access_scope: 'all')
    expect(described_class::Scope.new(agent_context, account.crm_tasks).resolve).to contain_exactly(
      own_task, team_task, outside_task
    )
  end

  it 'intersects view and view_reports across none, own, team, and all scopes' do
    teammate = create(:user, account: account)
    outsider = create(:user, account: account)
    team = create(:team, account: account)
    create(:team_member, team: team, user: agent)
    create(:team_member, team: team, user: teammate)
    own_task = create(:crm_task, account: account, assignee: agent)
    team_task = create(:crm_task, account: account, assignee: teammate, team: team)
    outside_task = create(:crm_task, account: account, assignee: outsider)
    enforce_access_roles!
    grants = agent.account_users.find_by!(account: account).access_role.grants.where(resource: 'tasks')
    grants.find_by!(capability: 'view').update!(access_scope: 'all')
    report_grant = grants.create!(
      account: account,
      capability: 'view_reports',
      access_scope: 'none'
    )

    report_grant.update!(access_scope: 'none')
    expect(report_scope).to be_empty

    report_grant.update!(access_scope: 'own')
    expect(report_scope).to contain_exactly(own_task)

    report_grant.update!(access_scope: 'team')
    expect(report_scope).to contain_exactly(own_task, team_task)

    report_grant.update!(access_scope: 'all')
    expect(report_scope).to contain_exactly(own_task, team_task, outside_task)
  end

  def enforce_access_roles!
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end

  def report_scope
    described_class::Scope.intersection(
      agent_context,
      account.crm_tasks,
      capabilities: %w[view view_reports]
    )
  end
end
