require 'rails_helper'

RSpec.describe AccessControl::ShadowResolver do
  describe '.call' do
    it 'returns the normalized scope from the assigned role' do
      account = create(:account)
      AccessControl::SystemRoleBootstrapper.call(account: account)
      account_user = create(:account_user, account: account, role: :agent)

      result = described_class.call(account_user: account_user, resource: 'contacts', capability: 'view')

      expect(result).to have_attributes(status: 'resolved', scope: 'own', reason: nil)
    end

    it 'returns none for a supported capability without a grant' do
      account = create(:account)
      AccessControl::SystemRoleBootstrapper.call(account: account)
      account_user = create(:account_user, account: account, role: :agent)

      result = described_class.call(account_user: account_user, resource: 'contacts', capability: 'configure')

      expect(result).to have_attributes(status: 'resolved', scope: 'none', reason: 'missing_grant')
    end

    it 'recognizes schema-independent Automation management without bootstrapping a grant' do
      account = create(:account)
      AccessControl::SystemRoleBootstrapper.call(account: account)
      account_user = create(:account_user, account: account, role: :administrator)

      result = described_class.call(account_user: account_user, resource: 'automation_rules', capability: 'manage')

      expect(result).to have_attributes(status: 'resolved', scope: 'none', reason: 'missing_grant')
    end

    it 'is unresolved when no access role is assigned' do
      account_user = create(:account_user)

      result = described_class.call(account_user: account_user, resource: 'contacts', capability: 'view')

      expect(result).to have_attributes(status: 'unresolved', scope: 'none', reason: 'missing_access_role')
    end

    it 'rejects a cross-account role even before model validation' do
      account_user = create(:account_user)
      account_user.access_role = create(:access_role)

      result = described_class.call(account_user: account_user, resource: 'contacts', capability: 'view')

      expect(result).to have_attributes(status: 'unresolved', scope: 'none', reason: 'cross_account_access_role')
    end

    it 'rejects unsupported resource-capability pairs' do
      account_user = create(:account_user)

      expect do
        described_class.call(account_user: account_user, resource: 'contacts', capability: 'take')
      end.to raise_error(ArgumentError, 'Unsupported capability for contacts: take')
    end
  end
end
