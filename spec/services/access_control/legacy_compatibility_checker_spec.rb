require 'rails_helper'

RSpec.describe AccessControl::LegacyCompatibilityChecker do
  describe '.call' do
    it 'matches system and supported custom-role assignments' do
      account = create(:account)
      AccessControl::SystemRoleBootstrapper.call(account: account)
      create(:account_user, account: account, role: :administrator)
      custom_role = create(:custom_role, account: account, permissions: %w[contact_manage crm_task_view])
      AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
      create(:account_user, account: account, role: :agent, custom_role: custom_role)

      result = described_class.call(account: account)

      expect(result.counts).to eq('matched' => 2)
      expect(result.entries).to all(have_attributes(differences: [], details: []))
    end

    it 'reports identity and exact grant differences without writing' do
      account = create(:account)
      roles = AccessControl::SystemRoleBootstrapper.call(account: account).roles_by_key
      account_user = create(:account_user, account: account, role: :agent)
      roles.fetch('employee').grants.find_by!(resource: 'contacts', capability: 'view').update!(access_scope: 'team')
      account_user.update!(access_role: roles.fetch('observer'))

      expect do
        result = described_class.call(account: account)
        entry = result.entries.fetch(0)

        expect(entry.status).to eq('mismatch')
        expect(entry.details).to include('identity_mismatch', 'grant_mismatch')
        expect(entry.differences).to include(
          { resource: 'contacts', capability: 'create', expected_scope: 'own', actual_scope: 'none' }
        )
      end.not_to(change { account_user.reload.access_role_id })
    end

    it 'classifies ambiguous and unsupported legacy identities for review' do
      account = create(:account)
      supported = create(:custom_role, account: account, permissions: %w[crm_task_view])
      unsupported = create(:custom_role, account: account, permissions: %w[report_manage])
      create(:account_user, account: account, role: :administrator, custom_role: supported)
      create(:account_user, account: account, role: :agent, custom_role: unsupported)

      result = described_class.call(account: account)

      expect(result.counts).to eq('conflict' => 1, 'review_required' => 1)
      expect(result.entries.find { |entry| entry.status == 'review_required' }.details).to eq(%w[report_manage])
    end

    it 'does not include users from another account' do
      account = create(:account)
      other_account = create(:account)
      create(:account_user, account: account)
      create(:account_user, account: other_account)

      result = described_class.call(account: account)

      expect(result.entries.map(&:account_user_id)).to match_array(account.account_user_ids)
    end

    it 'checks active lifecycle snapshots and ignores completed snapshots' do
      account = create(:account)
      roles = AccessControl::SystemRoleBootstrapper.call(account: account).roles_by_key
      active_snapshot = create(
        :account_user_lifecycle_snapshot,
        account: account,
        role: 'agent',
        access_role: roles.fetch('employee')
      )
      create(
        :account_user_lifecycle_snapshot,
        account: account,
        role: 'administrator',
        reactivated_at: Time.current
      )

      result = described_class.call(account: account)

      expect(result.counts).to eq('matched' => 1)
      expect(result.entries.first).to have_attributes(
        account_user_id: nil,
        lifecycle_snapshot_id: active_snapshot.id
      )
    end
  end
end
