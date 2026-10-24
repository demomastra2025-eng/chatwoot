require 'rails_helper'

RSpec.describe Conversations::ResolutionJob do
  subject(:job) { described_class.perform_later(account: account) }

  let!(:account) { create(:account) }
  let(:label) { create(:label, title: 'auto-resolved', account: account) }
  let!(:conversation) { create(:conversation, account: account) }

  it 'enqueues the job' do
    expect { job }.to have_enqueued_job(described_class)
      .with(account: account)
      .on_queue('low')
  end

  it 'does nothing when there is no auto resolve duration' do
    described_class.perform_now(account: account)
    expect(conversation.reload.status).to eq('open')
  end

  context 'when auto_resolve_ignore_waiting is true' do
    it 'resolves non-waiting conversations if time of inactivity is more than auto resolve duration' do
      account.update(auto_resolve_after: 14_400, auto_resolve_ignore_waiting: true) # 10 days in minutes
      conversation.update(last_activity_at: 13.days.ago, waiting_since: nil)
      described_class.perform_now(account: account)
      expect(conversation.reload.status).to eq('resolved')
    end

    it 'does not resolve waiting conversations even if time of inactivity is more than auto resolve duration' do
      account.update(auto_resolve_after: 14_400, auto_resolve_ignore_waiting: true) # 10 days in minutes
      conversation.update(last_activity_at: 13.days.ago, waiting_since: 13.days.ago)
      described_class.perform_now(account: account)
      expect(conversation.reload.status).to eq('open')
    end
  end

  context 'when auto_resolve_ignore_waiting is false' do
    it 'resolves all conversations if time of inactivity is more than auto resolve duration' do
      account.update(auto_resolve_after: 14_400, auto_resolve_ignore_waiting: false) # 10 days in minutes
      # Create one waiting conversation and one non-waiting conversation
      waiting_conversation = create(:conversation, account: account, last_activity_at: 13.days.ago, waiting_since: 13.days.ago)
      non_waiting_conversation = create(:conversation, account: account, last_activity_at: 13.days.ago, waiting_since: nil)

      described_class.perform_now(account: account)

      expect(waiting_conversation.reload.status).to eq('resolved')
      expect(non_waiting_conversation.reload.status).to eq('resolved')
    end
  end

  # When a contact is deleted, there's a brief window (~50-150ms) where contact_id becomes nil
  # but conversations still exist. If ResolutionJob runs during this window, muted? can crash
  # trying to call blocked? on nil. Fixes # (issue).
  it 'skips orphan conversations without a contact' do
    account.update(auto_resolve_after: 14_400, auto_resolve_ignore_waiting: false) # 10 days in minutes
    orphan_conversation = create(:conversation, account: account, last_activity_at: 13.days.ago, waiting_since: nil)
    orphan_conversation.update_columns(contact_id: nil, contact_inbox_id: nil) # rubocop:disable Rails/SkipsModelValidations
    resolvable_conversation = create(:conversation, account: account, last_activity_at: 13.days.ago, waiting_since: nil)

    described_class.perform_now(account: account)

    expect(orphan_conversation.reload.status).to eq('open')
    expect(resolvable_conversation.reload.status).to eq('resolved')
  end

  it 'adds a label after resolution' do
    account.update(auto_resolve_label: 'auto-resolved', auto_resolve_after: 14_400)
    conversation = create(:conversation, account: account, last_activity_at: 13.days.ago, waiting_since: 13.days.ago)

    described_class.perform_now(account: account)

    expect(conversation.reload.status).to eq('resolved')
    expect(conversation.reload.label_list).to include('auto-resolved')
  end

  context 'when the same person writes in several channels' do
    let(:contact) { create(:contact, account: account) }
    let(:quiet_inbox) { create(:inbox, account: account) }
    let(:live_inbox) { create(:inbox, account: account) }
    let!(:quiet_conversation) do
      create(:conversation, account: account, inbox: quiet_inbox, contact: contact,
                            contact_inbox: create(:contact_inbox, contact: contact, inbox: quiet_inbox),
                            last_activity_at: 13.days.ago)
    end
    let!(:other_conversation) do
      create(:conversation, account: account, inbox: live_inbox, contact: contact,
                            contact_inbox: create(:contact_inbox, contact: contact, inbox: live_inbox),
                            last_activity_at: 12.days.ago)
    end

    def create_message(conversation, created_at: 1.hour.ago, **attributes)
      create(:message, { account: account, inbox: conversation.inbox, conversation: conversation, sender: contact,
                         message_type: :incoming, private: false, created_at: created_at }.merge(attributes))
    end

    before { account.update(auto_resolve_after: 14_400, auto_resolve_ignore_waiting: false) } # 10 days in minutes

    it 'does not close a quiet channel while the person writes in another one' do
      create_message(other_conversation)

      described_class.perform_now(account: account)

      expect(quiet_conversation.reload.status).to eq('open')
      expect(other_conversation.reload.status).to eq('open')
    end

    it 'does not close a quiet channel while the person is answered in another one' do
      create_message(other_conversation, message_type: :outgoing, sender: create(:user, account: account))

      described_class.perform_now(account: account)

      expect(quiet_conversation.reload.status).to eq('open')
    end

    it 'closes the quiet channel once the person is quiet everywhere' do
      create_message(other_conversation, created_at: 11.days.ago)
      # The incoming message also triggers automatic template replies, which touch the conversation.
      other_conversation.update!(last_activity_at: 11.days.ago)

      described_class.perform_now(account: account)

      expect(quiet_conversation.reload.status).to eq('resolved')
      expect(other_conversation.reload.status).to eq('resolved')
    end

    it 'ignores private notes, activity lines and templates of the other channel' do
      create_message(other_conversation, private: true, message_type: :outgoing, sender: create(:user, account: account))
      create_message(other_conversation, message_type: :activity, sender: nil, content: 'Assigned to somebody')
      create_message(other_conversation, message_type: :template, sender: nil, content: 'Auto message')

      described_class.perform_now(account: account)

      expect(quiet_conversation.reload.status).to eq('resolved')
    end

    it 'does not look at the messages of another person' do
      stranger = create(:contact, account: account)
      create_message(create(:conversation, account: account, contact: stranger), sender: stranger)

      described_class.perform_now(account: account)

      expect(quiet_conversation.reload.status).to eq('resolved')
    end

    context 'when the account has an auto resolve message' do
      before { account.update(auto_resolve_message: 'Closed because of inactivity') }

      def auto_resolve_messages(conversation)
        conversation.messages.template.where(content: 'Closed because of inactivity')
      end

      it 'sends it once, in the channel of the latest activity' do
        described_class.perform_now(account: account)

        expect(quiet_conversation.reload.status).to eq('resolved')
        expect(other_conversation.reload.status).to eq('resolved')
        expect(auto_resolve_messages(other_conversation).count).to eq(1)
        expect(auto_resolve_messages(quiet_conversation).count).to eq(0)
      end

      it 'falls back to the next channel when the latest one cannot be written to' do
        allow(Conversations::MessageWindowService).to receive(:new) do |conversation|
          instance_double(Conversations::MessageWindowService, can_reply?: conversation.id != other_conversation.id)
        end

        described_class.perform_now(account: account)

        expect(auto_resolve_messages(quiet_conversation).count).to eq(1)
        expect(auto_resolve_messages(other_conversation).count).to eq(0)
      end

      it 'still sends it for a person with a single channel' do
        other_conversation.update!(status: :resolved)

        described_class.perform_now(account: account)

        expect(auto_resolve_messages(quiet_conversation).count).to eq(1)
      end
    end
  end

  it 'resolves only a limited number of conversations in a single execution' do
    stub_const('Limits::BULK_ACTIONS_LIMIT', 2)
    account.update(auto_resolve_after: 14_400, auto_resolve_ignore_waiting: false) # 10 days in minutes
    create_list(:conversation, 3, account: account, last_activity_at: 13.days.ago)
    described_class.perform_now(account: account)
    expect(account.conversations.resolved.count).to eq(Limits::BULK_ACTIONS_LIMIT)
  end
end
