require 'rails_helper'

RSpec.describe Messages::DeleteService do
  describe '#perform' do
    it 'deletes telegram personal outgoing messages in provider and preserves telegram metadata locally' do
      channel = double('Channel::TelegramPersonal')
      allow(channel).to receive(:is_a?).with(Channel::TelegramPersonal).and_return(true)
      allow(channel).to receive(:delete_message)

      inbox = instance_double(Inbox, channel: channel)
      conversation = instance_double(Conversation, inbox: inbox)
      attachments = double('attachments')
      allow(attachments).to receive(:destroy_all)

      message = instance_double(
        Message,
        conversation: conversation,
        outgoing?: true,
        private?: false,
        source_id: '101',
        content_attributes: { 'telegram_message_ids' => %w[101 102], 'grouped_id' => '9001' },
        attachments: attachments
      )
      allow(message).to receive(:update!)

      I18n.with_locale(:en) do
        expect(channel).to receive(:delete_message).with(message: message)
        expect(message).to receive(:update!).with(
          hash_including(
            content: I18n.t('conversations.messages.deleted'),
            content_type: :text,
            content_attributes: hash_including(
              'telegram_message_ids' => %w[101 102],
              'grouped_id' => '9001',
              deleted: true
            )
          )
        )
        expect(attachments).to receive(:destroy_all)

        described_class.new(message: message).perform
      end
    end

    it 'rejects deleting telegram personal incoming messages through provider flow' do
      channel = double('Channel::TelegramPersonal')
      allow(channel).to receive(:is_a?).with(Channel::TelegramPersonal).and_return(true)

      inbox = instance_double(Inbox, channel: channel)
      conversation = instance_double(Conversation, inbox: inbox)
      message = instance_double(
        Message,
        conversation: conversation,
        outgoing?: false,
        private?: false,
        source_id: '101',
        content_attributes: {}
      )

      expect do
        described_class.new(message: message).perform
      end.to raise_error(Messages::DeleteService::Error, 'Only outgoing Telegram Personal messages can be deleted')
    end

    it 'deletes WhatsApp Web outgoing messages within 48 hours through the channel' do
      channel = create(:channel_whatsapp_web)
      conversation = create(:conversation, account: channel.account, inbox: channel.inbox)
      message = create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        message_type: :outgoing,
        source_id: 'wa-del-1',
        content: 'to be deleted'
      )

      expect(channel).to receive(:delete_message).with(message: message)

      described_class.new(message: message).perform

      expect(message.reload.deleted).to eq(true)
    end

    it 'rejects deleting WhatsApp Web messages older than 48 hours' do
      channel = create(:channel_whatsapp_web)
      conversation = create(:conversation, account: channel.account, inbox: channel.inbox)
      message = create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        message_type: :outgoing,
        source_id: 'wa-del-old',
        content: 'too old',
        created_at: 49.hours.ago
      )

      expect(channel).not_to receive(:delete_message)

      expect do
        described_class.new(message: message).perform
      end.to raise_error(Messages::DeleteService::Error, 'WhatsApp Web message deletion window has expired')
    end

    it 'deletes Telegram Bot outgoing messages within 48 hours through the channel' do
      channel = create(:channel_telegram)
      conversation = create(
        :conversation,
        account: channel.account,
        inbox: channel.inbox,
        additional_attributes: { 'chat_id' => '123' }
      )
      message = create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        message_type: :outgoing,
        source_id: '202',
        content: 'telegram bot text'
      )

      expect(channel).to receive(:delete_message).with(message: message)

      described_class.new(message: message).perform

      expect(message.reload.deleted).to eq(true)
    end

    it 'rejects deleting non-private messages on official WhatsApp Cloud API channels' do
      channel = create(:channel_whatsapp, sync_templates: false, validate_provider_config: false)
      conversation = create(:conversation, account: channel.account, inbox: channel.inbox)
      message = create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        message_type: :outgoing,
        source_id: 'wamid.123',
        content: 'cannot be deleted from client phone'
      )

      expect do
        described_class.new(message: message).perform
      end.to raise_error(Messages::DeleteService::Error, 'Message deletion is not supported for Whatsapp')
    end

    it 'allows deleting internal private notes on any channel without calling provider' do
      channel = create(:channel_whatsapp, sync_templates: false, validate_provider_config: false)
      conversation = create(:conversation, account: channel.account, inbox: channel.inbox)
      note = create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        message_type: :outgoing,
        private: true,
        content: 'internal note'
      )

      described_class.new(message: note).perform

      expect(note.reload.deleted).to eq(true)
    end
  end
end
