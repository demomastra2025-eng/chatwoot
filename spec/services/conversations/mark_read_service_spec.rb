require 'rails_helper'

RSpec.describe Conversations::MarkReadService do
  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com',
      'TELEGRAM_PERSONAL_DEFAULT_API_ID' => nil,
      'TELEGRAM_PERSONAL_DEFAULT_API_HASH' => nil
    ) do
      example.run
    end
  end

  describe '#perform' do
    let(:user) { create(:user, account: channel.account, role: :agent) }

    before do
      create(:inbox_member, user: user, inbox: channel.inbox)
    end

    context 'when syncing WhatsApp Web read receipts' do
      let(:channel) { create(:channel_whatsapp_web) }
      let(:contact) do
        create(
          :contact,
          account: channel.account,
          additional_attributes: {
            canonical_jid: '15551234567@s.whatsapp.net'
          }
        )
      end
      let(:contact_inbox) do
        create(
          :contact_inbox,
          contact: contact,
          inbox: channel.inbox,
          source_id: '15551234567'
        )
      end
      let(:conversation) do
        create(
          :conversation,
          account: channel.account,
          inbox: channel.inbox,
          contact: contact,
          contact_inbox: contact_inbox,
          agent_last_seen_at: 30.minutes.ago
        )
      end
      let!(:incoming_message) do
        create(
          :message,
          account: channel.account,
          inbox: channel.inbox,
          conversation: conversation,
          sender: contact,
          message_type: :incoming,
          source_id: 'wa-incoming-1',
          content: 'large payload',
          created_at: 5.minutes.ago
        )
      end

      it 'passes a lightweight unread message projection to the sync service' do
        sync_service = instance_double(WhatsappWeb::MarkMessagesReadService, perform: true)
        projected_message = nil
        synced_conversation = conversation

        expect(WhatsappWeb::MarkMessagesReadService).to receive(:new) do |conversation:, messages:|
          expect(conversation).to eq(synced_conversation)
          projected_message = messages.find { |message| message.id == incoming_message.id }
          sync_service
        end
        expect(sync_service).to receive(:perform)

        described_class.new(conversation: conversation, user: user).perform

        expect(projected_message.source_id).to eq('wa-incoming-1')
        expect { projected_message.content }.to raise_error(ActiveModel::MissingAttributeError)
      end
    end

    context 'when syncing WhatsApp Cloud read receipts' do
      let(:channel) do
        create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
      end
      let(:contact) { create(:contact, account: channel.account) }
      let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: channel.inbox, source_id: '15551234567') }
      let(:conversation) do
        create(
          :conversation,
          account: channel.account,
          inbox: channel.inbox,
          contact: contact,
          contact_inbox: contact_inbox,
          agent_last_seen_at: 30.minutes.ago
        )
      end
      let!(:incoming_message) do
        create(
          :message,
          account: channel.account,
          inbox: channel.inbox,
          conversation: conversation,
          sender: contact,
          message_type: :incoming,
          source_id: 'wamid.cloud-incoming-1',
          created_at: 5.minutes.ago
        )
      end
      let!(:imported_message) do
        create(
          :message,
          account: channel.account,
          inbox: channel.inbox,
          conversation: conversation,
          sender: contact,
          message_type: :incoming,
          source_id: 'wamid.cloud-history-1',
          content_attributes: { imported_history: true, whatsapp_history_import: true },
          created_at: 10.minutes.ago
        )
      end

      it 'passes provider ids and timestamps to the Cloud sync service' do
        sync_service = instance_double(Whatsapp::MarkMessagesReadService, perform: true)
        projected_message = nil
        projected_message_ids = nil
        expected_conversation = conversation

        expect(Whatsapp::MarkMessagesReadService).to receive(:new) do |conversation:, messages:|
          expect(conversation).to eq(expected_conversation)
          projected_message_ids = messages.map(&:id)
          projected_message = messages.find { |message| message.id == incoming_message.id }
          sync_service
        end
        expect(sync_service).to receive(:perform)

        described_class.new(conversation: conversation, user: user).perform

        expect(projected_message).to have_attributes(
          source_id: 'wamid.cloud-incoming-1',
          created_at: incoming_message.reload.created_at
        )
        expect(projected_message_ids).to contain_exactly(incoming_message.id)
        expect(projected_message_ids).not_to include(imported_message.id)
      end

      it 'retries an aggregate refresh without replaying the read receipt' do
        incoming_message
        channel.account.enable_features!('communication_threads')
        conversation.reload.refresh_communication_thread!
        sync_service = instance_double(Whatsapp::MarkMessagesReadService, perform: true)
        allow(Whatsapp::MarkMessagesReadService).to receive(:new).and_return(sync_service)
        attempts = 0
        allow_any_instance_of(Conversations::CommunicationThreadResolver).to receive(:perform).and_wrap_original do |original|
          attempts += 1
          expect(sync_service).to have_received(:perform).once
          raise ActiveRecord::Deadlocked if attempts == 1

          original.call
        end

        described_class.new(conversation: conversation, user: user).perform

        expect(attempts).to eq(2)
        expect(sync_service).to have_received(:perform).once
        expect(conversation.reload.communication_thread.unread_count).to eq(0)
      end

      it 'delivers the captured receipt once even if the aggregate refresh exhausts its retries' do
        incoming_message
        channel.account.enable_features!('communication_threads')
        conversation.reload.refresh_communication_thread!
        sync_service = instance_double(Whatsapp::MarkMessagesReadService, perform: true)
        allow(Whatsapp::MarkMessagesReadService).to receive(:new).and_return(sync_service)
        allow_any_instance_of(Conversations::CommunicationThreadResolver).to receive(:perform).and_raise(ActiveRecord::Deadlocked)

        expect do
          described_class.new(conversation: conversation, user: user).perform
        end.to raise_error(ActiveRecord::Deadlocked)

        expect(sync_service).to have_received(:perform).once
        expect(conversation.reload.unread_messages_for(user).incoming).to be_empty
      end

      it 'creates a missing thread before broadcasting and delivers the captured receipt first' do
        incoming_message
        channel.account.enable_features!('communication_threads')
        expect(conversation.reload.communication_thread).to be_nil
        sync_service = instance_double(Whatsapp::MarkMessagesReadService, perform: true)
        allow(Whatsapp::MarkMessagesReadService).to receive(:new).and_return(sync_service)
        expect(conversation).to receive(:dispatch_read_state_update).with(actor: user).once do
          expect(sync_service).to have_received(:perform).once
          expect(conversation.reload.communication_thread.unread_count).to eq(0)
        end

        described_class.new(conversation: conversation, user: user).perform
      end

      it 'does not lose the captured receipt if a synchronous read-state listener fails' do
        incoming_message
        sync_service = instance_double(Whatsapp::MarkMessagesReadService, perform: true)
        allow(Whatsapp::MarkMessagesReadService).to receive(:new).and_return(sync_service)
        allow(conversation).to receive(:dispatch_read_state_update).and_raise(ActiveRecord::Deadlocked)

        expect do
          described_class.new(conversation: conversation, user: user).perform
        end.to raise_error(ActiveRecord::Deadlocked)

        expect(sync_service).to have_received(:perform).once
        expect(conversation.reload.unread_messages_for(user).incoming).to be_empty
      end
    end

    context 'when syncing Telegram Personal read receipts' do
      let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }
      let(:channel) { create(:channel_telegram_personal, account: account) }
      let(:contact) { create(:contact, account: channel.account) }
      let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: channel.inbox, source_id: '23') }
      let(:conversation) do
        create(
          :conversation,
          account: channel.account,
          inbox: channel.inbox,
          contact: contact,
          contact_inbox: contact_inbox,
          additional_attributes: { 'chat_id' => '23' },
          agent_last_seen_at: 30.minutes.ago
        )
      end
      let!(:incoming_message) do
        create(
          :message,
          account: channel.account,
          inbox: channel.inbox,
          conversation: conversation,
          sender: contact,
          message_type: :incoming,
          source_id: '101',
          content: 'telegram payload',
          content_attributes: { 'telegram_message_ids' => %w[101 102] },
          created_at: 5.minutes.ago
        )
      end

      it 'keeps only the attributes required by the sync service' do
        sync_service = instance_double(TelegramPersonal::MarkMessagesReadService, perform: true)
        projected_message = nil
        synced_conversation = conversation

        expect(TelegramPersonal::MarkMessagesReadService).to receive(:new) do |conversation:, messages:|
          expect(conversation).to eq(synced_conversation)
          projected_message = messages.find { |message| message.id == incoming_message.id }
          sync_service
        end
        expect(sync_service).to receive(:perform)

        described_class.new(conversation: conversation, user: user).perform

        expect(projected_message.content_attributes['telegram_message_ids']).to eq(%w[101 102])
        expect { projected_message.content }.to raise_error(ActiveModel::MissingAttributeError)
      end
    end

    context 'with multiple account users' do
      let(:channel) { create(:channel_api) }

      it 'marks the shared conversation read for every account member' do
        other_user = create(:user, account: channel.account, role: :agent)
        create(:inbox_member, user: other_user, inbox: channel.inbox)
        conversation = create(:conversation, account: channel.account, inbox: channel.inbox, agent_last_seen_at: nil)
        incoming_message = create(
          :message,
          account: channel.account,
          inbox: channel.inbox,
          conversation: conversation,
          message_type: :incoming,
          created_at: 5.minutes.ago
        )

        described_class.new(conversation: conversation, user: user).perform

        expect(conversation.reload.unread_messages_for(user).incoming).to be_empty
        expect(conversation.unread_messages_for(other_user).incoming).to be_empty
        expect(conversation.last_seen_at_for(other_user)).to eq(conversation.agent_last_seen_at)
        expect(incoming_message.reload.created_at).to be <= conversation.agent_last_seen_at
      end
    end
  end
end
