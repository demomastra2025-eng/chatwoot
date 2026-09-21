require 'rails_helper'

RSpec.describe AutomationRulePolicy, type: :policy do
  subject(:policy) { described_class.new(user_context, record) }

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:account_user) { user.account_users.find_by!(account: account) }
  let(:record) { AutomationRule }
  let(:user_context) { { user: user, account: account, account_user: account_user } }
  let(:actions) { %i[index? show? create? update? clone? destroy?] }

  it 'preserves administrator access in legacy mode' do
    administrator = create(:user, account: account, role: :administrator)
    context = {
      user: administrator,
      account: account,
      account_user: administrator.account_users.find_by!(account: account)
    }

    expect(actions).to all(satisfy { |action| described_class.new(context, record).public_send(action) })
  end

  it 'preserves legacy administrator access when a custom role is assigned' do
    administrator = create(:user, account: account, role: :administrator)
    administrator_account_user = administrator.account_users.find_by!(account: account)
    administrator_account_user.update!(custom_role: create(:custom_role, account: account, permissions: []))
    context = { user: administrator, account: account, account_user: administrator_account_user }

    expect(actions).to all(satisfy { |action| described_class.new(context, record).public_send(action) })
  end

  it 'allows the explicit legacy permission' do
    custom_role = create(:custom_role, account: account, permissions: %w[automation_manage])
    account_user.update!(custom_role: custom_role)

    expect(actions).to all(satisfy { |action| policy.public_send(action) })
  end

  it 'does not infer Automation access from deal or task grants' do
    custom_role = create(:custom_role, account: account, permissions: %w[crm_deal_manage crm_task_manage])
    account_user.update!(custom_role: custom_role)

    expect(actions).to all(satisfy { |action| !policy.public_send(action) })
  end

  it 'keeps legacy authority in enforced mode until Automation grants can be bootstrapped' do
    administrator = create(:user, account: account, role: :administrator)
    administrator_account_user = administrator.account_users.find_by!(account: account)
    context = { user: administrator, account: account, account_user: administrator_account_user }
    stub_mode_resolution(mode: 'enforced', scope: 'none', resolved_account_user: administrator_account_user)

    expect(actions).to all(satisfy { |action| described_class.new(context, record).public_send(action) })
  end

  it 'uses the explicit all grant as authoritative in enforced mode' do
    stub_mode_resolution(mode: 'enforced', scope: 'all')

    expect(actions).to all(satisfy { |action| policy.public_send(action) })
  end

  it 'fails closed without an explicit grant in enforced mode' do
    custom_role = create(:custom_role, account: account, permissions: %w[automation_manage])
    account_user.update!(custom_role: custom_role)
    stub_mode_resolution(mode: 'enforced', scope: 'none')

    expect(actions).to all(satisfy { |action| !policy.public_send(action) })
  end

  it 'keeps legacy authority and audits a shadow mismatch' do
    custom_role = create(:custom_role, account: account, permissions: %w[automation_manage])
    account_user.update!(custom_role: custom_role)
    stub_mode_resolution(mode: 'shadow', scope: 'none')
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(AccessControl::ModeAwareDecision::EVENT_NAME) do |*args|
      events << ActiveSupport::Notifications::Event.new(*args).payload
    end

    expect(policy.index?).to be(true)
    expect(events).to contain_exactly(
      include(
        account_id: account.id,
        account_user_id: account_user.id,
        resource: 'automation_rules',
        capability: 'manage',
        legacy_allowed: true,
        access_role_allowed: false,
        matched: false
      )
    )
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'rejects a record from another account before resolving grants' do
    foreign_rule = create(:automation_rule)
    policy = described_class.new(user_context, foreign_rule)

    expect(AccessControl::ModeResolver).not_to receive(:call)
    expect(policy.show?).to be(false)
  end

  private

  def stub_mode_resolution(mode:, scope:, resolved_account_user: account_user)
    access_role_resolution = AccessControl::ShadowResolver::Result.new(
      account_user_id: resolved_account_user.id,
      access_role_id: resolved_account_user.access_role_id,
      resource: 'automation_rules',
      capability: 'manage',
      scope: scope,
      status: 'resolved',
      reason: scope == 'none' ? 'missing_grant' : nil
    )
    mode_resolution = AccessControl::ModeResolver::Result.new(
      account_id: account.id,
      mode: mode,
      authoritative_source: mode == 'enforced' ? 'access_role' : 'legacy',
      access_role_resolution: access_role_resolution
    )
    allow(AccessControl::ModeResolver).to receive(:call).and_return(mode_resolution)
  end
end
