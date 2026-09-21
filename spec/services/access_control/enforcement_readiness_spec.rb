require 'rails_helper'

RSpec.describe AccessControl::EnforcementReadiness do
  describe '.call' do
    it 'reports every missing system role' do
      account = create(:account)

      result = described_class.call(account: account)

      expect(result).not_to be_ready
      expect(result.missing_system_roles).to match_array(AccessControl::SystemRoleCatalog::ROLE_NAMES.keys)
      expect(result.system_role_mismatches).to be_empty
    end

    it 'accepts exact presets and matched account-user assignments' do
      account = create(:account)
      AccessControl::SystemRoleBootstrapper.call(account: account)
      create(:account_user, account: account, role: :administrator)
      create(:account_user, account: account, role: :agent)

      result = described_class.call(account: account)

      expect(result).to be_ready
      expect(result.compatibility_counts).to eq('matched' => 2)
      expect(result.missing_system_roles).to be_empty
      expect(result.system_role_mismatches).to be_empty
    end

    it 'accepts an assigned legacy Automation manager' do
      account = create(:account)
      custom_role = create(:custom_role, account: account, permissions: %w[automation_manage])
      create(:account_user, account: account, role: :agent, custom_role: custom_role)
      AccessControl::LegacyRoleAssigner.call(account: account, apply: true)

      result = described_class.call(account: account)

      expect(result).to be_ready
      expect(result.compatibility_counts).to eq('matched' => 1)
    end

    it 'rejects a modified system preset even when the assigned user still points to it' do
      account = create(:account)
      roles = AccessControl::SystemRoleBootstrapper.call(account: account).roles_by_key
      create(:account_user, account: account, role: :agent)
      roles.fetch('observer').grants.find_by!(resource: 'contacts', capability: 'view').update!(access_scope: 'own')

      result = described_class.call(account: account)

      expect(result).not_to be_ready
      expect(result.system_role_mismatches).to eq(%w[observer])
    end

    it 'rejects conflict and review-required legacy identities' do
      account = create(:account)
      AccessControl::SystemRoleBootstrapper.call(account: account)
      supported = create(:custom_role, account: account, permissions: %w[crm_task_view])
      unsupported = create(:custom_role, account: account, permissions: %w[report_manage])
      create(:account_user, account: account, role: :administrator, custom_role: supported)
      create(:account_user, account: account, role: :agent, custom_role: unsupported)

      result = described_class.call(account: account)

      expect(result).not_to be_ready
      expect(result.compatibility_counts).to include('conflict' => 1, 'review_required' => 1)
    end

    it 'rejects an incompatible active lifecycle snapshot' do
      account = create(:account)
      AccessControl::SystemRoleBootstrapper.call(account: account)
      custom_role = create(:custom_role, account: account, permissions: %w[crm_task_view])
      snapshot = create(
        :account_user_lifecycle_snapshot,
        account: account,
        role: 'administrator',
        custom_role: custom_role
      )

      result = described_class.call(account: account)

      expect(result).not_to be_ready
      expect(result.compatibility_counts).to eq('conflict' => 1)
      expect(result).to have_attributes(account_id: snapshot.account_id)
    end

    it 'fails closed for an unknown compatibility status' do
      account = create(:account)
      AccessControl::SystemRoleBootstrapper.call(account: account)
      entry = AccessControl::LegacyCompatibilityChecker::Entry.new(
        account_user_id: nil,
        lifecycle_snapshot_id: nil,
        user_id: nil,
        status: 'pending_future_check',
        expected_identity: nil,
        actual_identity: nil,
        differences: [],
        details: []
      )
      compatibility = AccessControl::LegacyCompatibilityChecker::Result.new(account_id: account.id, entries: [entry])
      allow(AccessControl::LegacyCompatibilityChecker).to receive(:call).and_return(compatibility)

      result = described_class.call(account: account)

      expect(result).not_to be_ready
      expect(result.compatibility_counts).to eq('pending_future_check' => 1)
    end
  end
end
