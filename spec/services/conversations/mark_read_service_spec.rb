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

      it 'passes provider ids and timestamps to the Cloud sync service' do
        sync_service = instance_double(Whatsapp::MarkMessagesReadService, perform: true)
        projected_message = nil
        expected_conversation = conversation

        expect(Whatsapp::MarkMessagesReadService).to receive(:new) do |conversation:, messages:|
          expect(conversation).to eq(expected_conversation)
          projected_message = messages.find { |message| message.id == incoming_message.id }
          sync_service
        end
        expect(sync_service).to receive(:perform)

        described_class.new(conversation: conversation, user: user).perform

        expect(projected_message).to have_attributes(
          source_id: 'wamid.cloud-incoming-1',
          created_at: incoming_message.reload.created_at
        )
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
  end
end
