require 'rails_helper'

RSpec.describe AccessControl::LegacyRoleBackfill do
  describe '.call' do
    it 'previews assignments and current mismatches without writes' do
      account = create(:account)
      create(:account_user, account: account, role: :agent)
      results = []

      summary = nil
      expect do
        summary = described_class.call(accounts: Account.where(id: account.id)) { |result| results << result }
      end.not_to change(AccessRole, :count)

      expect(summary).to have_attributes(apply: false, processed_accounts: 1, failed_accounts: 0)
      expect(summary.assignment_counts).to eq('assigned_employee' => 1)
      expect(summary.compatibility_counts).to eq('mismatch' => 1)
      expect(results.first.entries.first.fetch(:details)).to include('identity_mismatch')
    end

    it 'applies unambiguous assignments and reports parity' do
      account = create(:account)
      account_user = create(:account_user, account: account, role: :agent)
      snapshot = create(:account_user_lifecycle_snapshot, account: account, role: 'administrator')

      summary = described_class.call(accounts: Account.where(id: account.id), apply: true)

      expect(summary).to have_attributes(apply: true, processed_accounts: 1, failed_accounts: 0)
      expect(summary.compatibility_counts).to eq('matched' => 2)
      expect(account_user.reload.access_role.system_key).to eq('employee')
      expect(snapshot.reload.access_role.system_key).to eq('administrator')
    end

    it 'is idempotent after a successful apply' do
      account = create(:account)
      create(:account_user, account: account, role: :agent)
      accounts = Account.where(id: account.id)
      described_class.call(accounts: accounts, apply: true)

      expect do
        summary = described_class.call(accounts: accounts, apply: true)

        expect(summary.assignment_counts).to eq('already_assigned' => 1)
        expect(summary.compatibility_counts).to eq('matched' => 1)
      end.not_to(change { [AccessRole.count, AccessRoleGrant.count] })
    end

    it 'rolls back a failed account and continues with the next account' do
      failed_account = create(:account)
      successful_account = create(:account)
      failed_user = create(:account_user, account: failed_account, role: :agent)
      successful_user = create(:account_user, account: successful_account, role: :agent)
      results = []
      allow(AccessControl::LegacyCompatibilityChecker).to receive(:call).and_wrap_original do |method, account:|
        raise ActiveRecord::RecordInvalid if account == failed_account

        method.call(account: account)
      end

      summary = described_class.call(
        accounts: Account.where(id: [failed_account.id, successful_account.id]),
        apply: true,
        batch_size: 1
      ) { |result| results << result }

      expect(summary).to have_attributes(processed_accounts: 2, failed_accounts: 1)
      expect(results.find { |result| result.account_id == failed_account.id }.error).to eq('ActiveRecord::RecordInvalid')
      expect(failed_user.reload.access_role).to be_nil
      expect(failed_account.access_roles).to be_empty
      expect(successful_user.reload.access_role.system_key).to eq('employee')
    end

    it 'rolls back apply when the post-write comparison still has a mismatch' do
      account = create(:account)
      account_user = create(:account_user, account: account, role: :agent)
      mismatch = AccessControl::LegacyCompatibilityChecker::Entry.new(
        account_user_id: account_user.id,
        lifecycle_snapshot_id: nil,
        user_id: account_user.user_id,
        status: 'mismatch',
        expected_identity: nil,
        actual_identity: nil,
        differences: [],
        details: ['identity_mismatch']
      )
      comparison = AccessControl::LegacyCompatibilityChecker::Result.new(account_id: account.id, entries: [mismatch])
      allow(AccessControl::LegacyCompatibilityChecker).to receive(:call).and_return(comparison)
      result = nil

      summary = described_class.call(accounts: Account.where(id: account.id), apply: true) { |entry| result = entry }

      expect(summary).to have_attributes(processed_accounts: 1, failed_accounts: 1)
      expect(result.error).to eq('AccessControl::LegacyRoleBackfill::ParityMismatch')
      expect(account_user.reload.access_role).to be_nil
      expect(account.access_roles).to be_empty
    end

    it 'rejects a non-positive batch size' do
      expect { described_class.call(batch_size: 0) }.to raise_error(ArgumentError, 'batch_size must be positive')
    end
  end
end
