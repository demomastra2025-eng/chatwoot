require 'rails_helper'

RSpec.describe AccessControl::LegacyRoleAssigner do
  let(:account) { create(:account) }
  let(:supported_custom_role) { create(:custom_role, account: account, permissions: %w[contact_manage crm_deal_view]) }
  let(:unsupported_custom_role) { create(:custom_role, account: account, permissions: %w[conversation_participating_manage]) }
  let!(:administrator) { create(:account_user, account: account, role: :administrator) }
  let!(:employee) { create(:account_user, account: account, role: :agent) }
  let!(:custom_role_user) { create(:account_user, account: account, role: :agent, custom_role: supported_custom_role) }
  let!(:conflicting_user) { create(:account_user, account: account, role: :administrator, custom_role: supported_custom_role) }
  let!(:review_user) { create(:account_user, account: account, role: :agent, custom_role: unsupported_custom_role) }

  describe '.call' do
    it 'previews every decision without writing roles or assignments' do
      result = nil
      expect { result = described_class.call(account: account) }.not_to change(AccessRole, :count)

      expect(result.counts).to eq(
        'assigned_administrator' => 1,
        'assigned_employee' => 1,
        'assigned_custom_role' => 1,
        'conflict' => 1,
        'review_required' => 1
      )
      expect(account.account_users.where.not(access_role_id: nil)).not_to exist
    end

    it 'assigns only unambiguous users and leaves conflicts for review' do
      stale_role = create(:access_role, account: account)
      conflicting_user.update!(access_role: stale_role)
      review_user.update!(access_role: stale_role)

      result = described_class.call(account: account, apply: true)

      expect(result.counts).to eq(
        'assigned_administrator' => 1,
        'assigned_employee' => 1,
        'assigned_custom_role' => 1,
        'conflict' => 1,
        'review_required' => 1
      )
      expect(administrator.reload.access_role.system_key).to eq('administrator')
      expect(employee.reload.access_role.system_key).to eq('employee')
      expect(custom_role_user.reload.access_role.legacy_custom_role_id).to eq(supported_custom_role.id)
      expect(conflicting_user.reload.access_role).to be_nil
      expect(review_user.reload.access_role).to be_nil
    end

    it 'is idempotent after applying assignments' do
      described_class.call(account: account, apply: true)

      expect do
        result = described_class.call(account: account, apply: true)
        expect(result.counts).to eq('already_assigned' => 3, 'conflict' => 1, 'review_required' => 1)
      end.not_to(change { [AccessRole.count, AccessRoleGrant.count] })
    end

    it 'reloads a stale AccountUser under row lock before assignment' do
      roles = AccessControl::SystemRoleBootstrapper.call(account: account).roles_by_key
      stale_account_user = employee.reload
      # Simulate a concurrent committed write while retaining the stale in-memory instance.
      AccountUser.where(id: employee.id).update_all( # rubocop:disable Rails/SkipsModelValidations
        role: AccountUser.roles.fetch('administrator')
      )

      result = described_class.new(account, apply: true).send(:classify_with_lock, stale_account_user, roles)

      expect(result.status).to eq('assigned_administrator')
      expect(employee.reload.access_role).to eq(roles.fetch('administrator'))
    end

    it 'assigns active lifecycle snapshots and ignores completed snapshots' do
      snapshot_account = create(:account)
      active_snapshot = create(:account_user_lifecycle_snapshot, account: snapshot_account, role: 'agent')
      completed_snapshot = create(
        :account_user_lifecycle_snapshot,
        account: snapshot_account,
        role: 'administrator',
        reactivated_at: Time.current
      )

      result = described_class.call(account: snapshot_account, apply: true)

      expect(result.counts).to eq('assigned_employee' => 1)
      expect(result.entries.first).to have_attributes(
        account_user_id: nil,
        lifecycle_snapshot_id: active_snapshot.id
      )
      expect(active_snapshot.reload.access_role.system_key).to eq('employee')
      expect(completed_snapshot.reload.access_role).to be_nil
    end
  end
end
