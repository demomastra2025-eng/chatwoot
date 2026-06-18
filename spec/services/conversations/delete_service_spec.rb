require 'rails_helper'

RSpec.describe Conversations::DeleteService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:ip) { '127.0.0.1' }

  before do
    allow(DeleteObjectJob).to receive(:perform_later)
    allow(Imap::DeletedMessageTracker).to receive(:new).and_call_original
  end

  describe '#perform' do
    context 'when deleting an email conversation' do
      let(:channel) { create(:channel_email, :imap_email, account: account) }
      let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }
      let(:deleted_message_tracker) { instance_double(Imap::DeletedMessageTracker, record: true) }

      before do
        allow(Imap::DeletedMessageTracker).to receive(:new).with(inbox: channel.inbox).and_return(deleted_message_tracker)
      end

      it 'records incoming message source ids before enqueueing deletion' do
        create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: :incoming, source_id: 'incoming-source-1')
        create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: :incoming, source_id: 'incoming-source-2')
        create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing, source_id: 'outgoing-source')

        described_class.new(conversation: conversation, user: user, ip: ip).perform

        expect(deleted_message_tracker).to have_received(:record).with(match_array(%w[incoming-source-1 incoming-source-2]))
        expect(DeleteObjectJob).to have_received(:perform_later).with(conversation, user, ip)
      end
    end

    context 'when deleting a non-email conversation' do
      let(:conversation) { create(:conversation, account: account) }

      it 'only enqueues deletion' do
        described_class.new(conversation: conversation, user: user, ip: ip).perform

        expect(Imap::DeletedMessageTracker).not_to have_received(:new)
        expect(DeleteObjectJob).to have_received(:perform_later).with(conversation, user, ip)
      end
    end
  end
end
