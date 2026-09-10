require 'rails_helper'

RSpec.describe Crm::DealPolicy, type: :policy do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:account_user) { agent.account_users.find_by!(account: account) }
  let(:user_context) { { user: agent, account: account, account_user: account_user } }
  let!(:own_deal) { create(:crm_deal, account: account, owner: agent) }
  let!(:other_deal) { create(:crm_deal, account: account, owner: create(:user, account: account)) }

  it 'preserves account-wide legacy access' do
    resolved = described_class::Scope.new(user_context, Crm::Deal).resolve

    expect(resolved).to contain_exactly(own_deal, other_deal)
    expect(described_class.new(user_context, other_deal).update?).to be(true)
  end

  it 'keeps legacy authoritative and emits the AccessRole comparison in shadow mode' do
    bootstrap_roles!(to: :shadow)
    events = []
    allow(Rails.logger).to receive(:warn)
    subscriber = ActiveSupport::Notifications.subscribe(AccessControl::ModeAwareDecision::EVENT_NAME) do |*args|
      events << ActiveSupport::Notifications::Event.new(*args).payload
    end

    expect(described_class::Scope.new(user_context, Crm::Deal).resolve).to contain_exactly(own_deal, other_deal)
    expect(described_class.new(user_context, other_deal).show?).to be(true)
    expect(events.find { |event| event[:decision_kind] == 'scope' }).to include(
      resource: 'deals', capability: 'view', legacy_scope: 'all', access_scope: 'own', matched: false
    )
    expect(events.find { |event| event[:decision_kind] == 'record' }).to include(
      resource: 'deals', capability: 'view', access_scope: 'own',
      legacy_allowed: true, access_role_allowed: false, matched: false
    )
    expect(Rails.logger).to have_received(:warn).with(include('[AccessControl::ShadowMismatch]')).twice
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'limits an employee to owned deals in enforced mode' do
    bootstrap_roles!(to: :enforced)
    resolved = described_class::Scope.new(user_context, Crm::Deal).resolve

    expect(resolved).to contain_exactly(own_deal)
    expect(described_class.new(user_context, own_deal).update?).to be(true)
    expect(described_class.new(user_context, other_deal).show?).to be(false)
  end

  it 'applies team scope to owned deals and deals with an explicit member team' do
    custom_role = create(:custom_role, account: account, permissions: %w[crm_deal_manage])
    account_user.update!(custom_role: custom_role)
    bootstrap_roles!(to: :enforced)
    account_user.reload.access_role.grants.where(resource: 'deals').find_each { |grant| grant.update!(access_scope: 'team') }
    team = create(:team, account: account)
    create(:team_member, team: team, user: agent)
    team_deal = create(:crm_deal, account: account, team: team, owner: nil)

    resolved = described_class::Scope.new(user_context, Crm::Deal).resolve

    expect(resolved).to contain_exactly(own_deal, team_deal)
    expect(described_class.new(user_context, team_deal).transition_stage?).to be(true)
    expect(described_class.new(user_context, other_deal).update?).to be(false)
  end

  it 'keeps view and mutation capabilities independent' do
    custom_role = create(:custom_role, account: account, permissions: %w[crm_deal_view])
    account_user.update!(custom_role: custom_role)
    bootstrap_roles!(to: :enforced)

    policy = described_class.new(user_context, other_deal)

    expect(policy.show?).to be(true)
    expect(policy.update?).to be(false)
    expect(policy.assign?).to be(false)
    expect(policy.archive?).to be(false)
  end

  def bootstrap_roles!(to:)
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced) if to == :enforced
  end
end
