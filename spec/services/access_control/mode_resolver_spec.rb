require 'rails_helper'

RSpec.describe AccessControl::ModeResolver do
  describe '.call' do
    it 'keeps legacy authoritative and skips AccessRole resolution in legacy mode' do
      account_user = create(:account_user)

      result = described_class.call(account_user: account_user, resource: 'contacts', capability: 'view')

      expect(result).to have_attributes(
        mode: 'legacy',
        authoritative_source: 'legacy',
        access_role_resolution: nil
      )
    end

    it 'computes a non-authoritative AccessRole result in shadow mode' do
      account = create(:account)
      AccessControl::SystemRoleBootstrapper.call(account: account)
      account_user = create(:account_user, account: account, role: :agent)
      AccessControl::ModeTransition.call(account: account, to: :shadow)

      result = described_class.call(account_user: account_user, resource: 'contacts', capability: 'view')

      expect(result.mode).to eq('shadow')
      expect(result.authoritative_source).to eq('legacy')
      expect(result.access_role_resolution).to have_attributes(status: 'resolved', scope: 'own')
    end

    it 'marks AccessRole as authoritative only after a guarded enforcement transition' do
      account = create(:account)
      AccessControl::SystemRoleBootstrapper.call(account: account)
      account_user = create(:account_user, account: account, role: :administrator)
      stale_account_user = AccountUser.find(account_user.id)
      expect(stale_account_user.account).to be_access_control_mode_legacy
      AccessControl::ModeTransition.call(account: account, to: :shadow)
      AccessControl::ModeTransition.call(account: account, to: :enforced)

      result = described_class.call(account_user: stale_account_user, resource: 'deals', capability: 'view')

      expect(result.mode).to eq('enforced')
      expect(result.authoritative_source).to eq('access_role')
      expect(result.access_role_resolution).to have_attributes(status: 'resolved', scope: 'all')
    end

    it 'reloads a preloaded authoritative role and grants before resolving enforced access' do
      account = create(:account)
      AccessControl::SystemRoleBootstrapper.call(account: account)
      account_user = create(:account_user, account: account, role: :administrator)
      AccessControl::ModeTransition.call(account: account, to: :shadow)
      AccessControl::ModeTransition.call(account: account, to: :enforced)
      stale_account_user = AccountUser.includes(access_role: :grants).find(account_user.id)
      stale_grant = stale_account_user.access_role.grants.find do |grant|
        grant.resource == 'contacts' && grant.capability == 'view'
      end
      expect(stale_grant.access_scope).to eq('all')
      AccessRoleGrant.find(stale_grant.id).update!(access_scope: 'own')

      result = described_class.call(account_user: stale_account_user, resource: 'contacts', capability: 'view')

      expect(result.access_role_resolution).to have_attributes(status: 'resolved', scope: 'own')
    end
  end
end
