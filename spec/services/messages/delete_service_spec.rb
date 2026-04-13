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
  end
end
