require 'rails_helper'

RSpec.describe AccountUserLifecycleSnapshot, '#access_role' do
  it 'accepts a legacy-compatible active snapshot in enforced mode' do
    account = create(:account)
    roles = AccessControl::SystemRoleBootstrapper.call(account: account).roles_by_key
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)

    snapshot = build(
      :account_user_lifecycle_snapshot,
      account: account,
      role: 'agent',
      access_role: roles.fetch('employee')
    )

    expect(snapshot).to be_valid
  end

  it 'rejects an incompatible active snapshot in enforced mode' do
    account = create(:account)
    roles = AccessControl::SystemRoleBootstrapper.call(account: account).roles_by_key
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)

    snapshot = build(
      :account_user_lifecycle_snapshot,
      account: account,
      role: 'agent',
      access_role: roles.fetch('observer')
    )

    expect(snapshot).not_to be_valid
    expect(snapshot.errors[:access_role]).to include('must match the legacy identity while access control is enforced')
  end
end
