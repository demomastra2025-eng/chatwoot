require 'rails_helper'

RSpec.describe Notification::DeleteNotificationJob do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:conversation) { create(:conversation, account: account) }

  context 'when enqueuing the job' do
    it 'enqueues the job to delete all notifications' do
      expect do
        described_class.perform_later(user, account, type: :all)
      end.to have_enqueued_job(described_class).on_queue('low')
    end

    it 'enqueues the job to delete read notifications' do
      expect do
        described_class.perform_later(user, account, type: :read)
      end.to have_enqueued_job(described_class).on_queue('low')
    end
  end

  context 'when performing the job' do
    before do
      create(:notification, account: account, user: user, primary_actor: conversation, read_at: nil)
      create(:notification, account: account, user: user, primary_actor: conversation, read_at: Time.current)
      create(:notification, account: other_account, user: user, read_at: Time.current)
    end

    it 'deletes all notifications for the requested account only' do
      described_class.perform_now(user, account, type: :all)
      expect(user.notifications.where(account_id: account.id).count).to eq(0)
      expect(user.notifications.where(account_id: other_account.id).count).to eq(1)
    end

    it 'deletes only read notifications for the requested account' do
      described_class.perform_now(user, account, type: :read)
      expect(user.notifications.where(account_id: account.id).count).to eq(1)
      expect(user.notifications.where(account_id: account.id, read_at: nil).count).to eq(1)
      expect(user.notifications.where(account_id: other_account.id).count).to eq(1)
    end
  end
end
