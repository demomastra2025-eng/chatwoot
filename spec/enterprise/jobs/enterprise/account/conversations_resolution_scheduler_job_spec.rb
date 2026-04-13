require 'rails_helper'

RSpec.describe Account::ConversationsResolutionSchedulerJob, type: :job do
  let(:account) { create(:account, auto_resolve_after: 60) }
  let(:assistant) { create(:captain_assistant, account: account) }

  describe '#perform - captain resolutions' do
    context 'when handling different inbox types' do
      let!(:regular_inbox) { create(:inbox, account: account) }
      let!(:email_inbox) { create(:inbox, :with_email, account: account) }

      before do
        create(:captain_inbox, captain_assistant: assistant, inbox: regular_inbox)
        create(:captain_inbox, captain_assistant: assistant, inbox: email_inbox)
      end

      it 'enqueues resolution jobs only for non-email inboxes with captain enabled' do
        expect do
          described_class.perform_now
        end.to have_enqueued_job(Captain::InboxPendingConversationsResolutionJob)
          .with(regular_inbox)
          .exactly(:once)
      end

      it 'does not enqueue resolution jobs for email inboxes even with captain enabled' do
        expect do
          described_class.perform_now
        end.not_to have_enqueued_job(Captain::InboxPendingConversationsResolutionJob)
          .with(email_inbox)
      end
    end

    context 'when account has captain auto resolve disabled' do
      let!(:regular_inbox) { create(:inbox, account: account) }

      before do
        create(:captain_inbox, captain_assistant: assistant, inbox: regular_inbox)
        account.update!(captain_auto_resolve_mode: 'disabled')
      end

      it 'does not enqueue resolution jobs' do
        expect do
          described_class.perform_now
        end.not_to have_enqueued_job(Captain::InboxPendingConversationsResolutionJob)
          .with(regular_inbox)
      end
    end

    context 'when account uses legacy disabled settings key' do
      let!(:regular_inbox) { create(:inbox, account: account) }

      before do
        create(:captain_inbox, captain_assistant: assistant, inbox: regular_inbox)
        account.update!(settings: account.settings.merge('captain_disable_auto_resolve' => true))
      end

      it 'does not enqueue resolution jobs' do
        expect do
          described_class.perform_now
        end.not_to have_enqueued_job(Captain::InboxPendingConversationsResolutionJob)
          .with(regular_inbox)
      end
    end

    context 'when conversation workflow auto-resolve is disabled' do
      let!(:regular_inbox) { create(:inbox, account: account) }

      before do
        create(:captain_inbox, captain_assistant: assistant, inbox: regular_inbox)
        account.update!(auto_resolve_after: nil)
      end

      it 'does not enqueue resolution jobs' do
        expect do
          described_class.perform_now
        end.not_to have_enqueued_job(Captain::InboxPendingConversationsResolutionJob)
          .with(regular_inbox)
      end
    end

    context 'when inbox has no captain enabled' do
      let!(:inbox_without_captain) { create(:inbox, account: create(:account)) }

      it 'does not enqueue resolution jobs' do
        expect do
          described_class.perform_now
        end.not_to have_enqueued_job(Captain::InboxPendingConversationsResolutionJob)
          .with(inbox_without_captain)
      end
    end

    context 'when a captain inbox points to a missing inbox record' do
      let(:captain_inboxes_scope) { instance_double(ActiveRecord::Relation) }
      let(:orphaned_captain_inbox) { instance_double(CaptainInbox, id: 123, inbox: nil) }

      before do
        allow(CaptainInbox).to receive(:all).and_return(captain_inboxes_scope)
        allow(captain_inboxes_scope).to receive(:find_each).with(batch_size: 100)
          .and_yield(orphaned_captain_inbox)
      end

      it 'skips the orphaned record without raising' do
        expect { described_class.perform_now }.not_to raise_error
      end

      it 'logs the orphaned record for follow-up' do
        expect(Rails.logger).to receive(:warn).with(
          '[CaptainInbox] skipping orphaned captain inbox id=123'
        )

        described_class.perform_now
      end
    end
  end
end
