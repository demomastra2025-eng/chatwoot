# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Crm::DealPolicy, type: :policy do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account) }
  let(:administrator) { create(:user, :administrator, account: account) }
  let(:deal) { create(:crm_deal, account: account) }

  let(:agent_context) { { user: agent, account: account, account_user: agent.account_users.find_by!(account: account) } }
  let(:administrator_context) { { user: administrator, account: account, account_user: administrator.account_users.find_by!(account: account) } }

  it 'allows plain agents to use deal runtime actions' do
    policy = described_class.new(agent_context, deal)

    aggregate_failures do
      expect(policy.index?).to be(true)
      expect(policy.show?).to be(true)
      expect(policy.timeline?).to be(true)
      expect(policy.view_reports?).to be(false)
      expect(policy.create?).to be(true)
      expect(policy.update?).to be(true)
      expect(policy.transition_stage?).to be(true)
      expect(policy.archive?).to be(true)
      expect(policy.unarchive?).to be(true)
    end
  end

  it 'allows administrators to use deal runtime actions' do
    policy = described_class.new(administrator_context, deal)

    aggregate_failures do
      expect(policy.index?).to be(true)
      expect(policy.show?).to be(true)
      expect(policy.timeline?).to be(true)
      expect(policy.view_reports?).to be(true)
      expect(policy.create?).to be(true)
      expect(policy.update?).to be(true)
      expect(policy.transition_stage?).to be(true)
      expect(policy.archive?).to be(true)
      expect(policy.unarchive?).to be(true)
    end
  end

  it 'preserves legacy report_manage access before enforced mode' do
    reporting_user = create(:user, account: account)
    reporting_role = create(:custom_role, account: account, permissions: ['report_manage'])
    account_user = reporting_user.account_users.find_by!(account: account)
    account_user.update!(custom_role: reporting_role)

    policy = described_class.new(
      { user: reporting_user, account: account, account_user: account_user },
      deal
    )

    expect(policy.view_reports?).to be(true)
  end

  it 'expands report owners from own, team, and all access scopes' do
    teammate = create(:user, account: account)
    outsider = create(:user, account: account)
    team = create(:team, account: account)
    create(:team_member, team: team, user: agent)
    create(:team_member, team: team, user: teammate)

    expect(described_class::Scope.owner_ids(agent_context, access_scope: 'own')).to eq([agent.id])
    expect(described_class::Scope.owner_ids(agent_context, access_scope: 'team')).to contain_exactly(agent.id, teammate.id)
    expect(described_class::Scope.owner_ids(agent_context, access_scope: 'all')).to include(agent.id, teammate.id, outsider.id)
  end
end
