require 'rails_helper'

RSpec.describe AccountDeletionService do
  let(:account) { create(:account) }
  let(:mailer) { instance_double(ActionMailer::MessageDelivery, deliver_later: nil) }

  describe '#perform' do
    before do
      allow(DeleteObjectJob).to receive(:perform_later)
      allow(AdministratorNotifications::AccountComplianceMailer).to receive(:with).and_return(
        instance_double(AdministratorNotifications::AccountComplianceMailer, account_deleted: mailer)
      )
    end

    it 'enqueues DeleteObjectJob with the account' do
      described_class.new(account: account).perform

      expect(DeleteObjectJob).to have_received(:perform_later).with(account)
    end

    it 'sends a compliance notification email' do
      described_class.new(account: account).perform

      expect(AdministratorNotifications::AccountComplianceMailer).to have_received(:with) do |args|
        expect(args[:account]).to eq(account)
        expect(args).to include(:soft_deleted_users)
      end
      expect(mailer).to have_received(:deliver_later)
    end

    context 'when handling users' do
      let(:user_with_one_account) { create(:user) }
      let(:user_with_multiple_accounts) { create(:user) }
      let(:second_account) { create(:account) }

      before do
        create(:account_user, user: user_with_one_account, account: account)
        create(:account_user, user: user_with_multiple_accounts, account: account)
        create(:account_user, user: user_with_multiple_accounts, account: second_account)
      end

      it 'soft deletes users who only belong to the deleted account' do
        original_email = user_with_one_account.email

        described_class.new(account: account).perform

        # Reload the user to get the updated email
        user_with_one_account.reload
        expect(user_with_one_account.email).to eq("#{user_with_one_account.id}@chatwoot-deleted.invalid")
        expect(user_with_one_account.email).not_to eq(original_email)
      end

      it 'does not rename a super admin whose only membership is the deleted account, so he can still sign in' do
        super_admin = create(:super_admin)
        create(:account_user, user: super_admin, account: account)
        original_email = super_admin.email

        service = described_class.new(account: account)
        service.perform

        expect(super_admin.reload.email).to eq(original_email)
        expect(service.soft_deleted_users.pluck(:id)).not_to include(super_admin.id.to_s)
        expect(service.soft_deleted_users.pluck(:id)).to include(user_with_one_account.id.to_s)
      end

      it 'does not modify emails for users belonging to multiple accounts' do
        original_email = user_with_multiple_accounts.email

        described_class.new(account: account).perform

        # Reload the user to get the updated email
        user_with_multiple_accounts.reload
        expect(user_with_multiple_accounts.email).to eq(original_email)
      end
    end
  end
end
