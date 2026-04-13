require 'rails_helper'

RSpec.describe TelegramPersonal::DeleteMessagesService do
  describe '#perform' do
    it 'marks album messages deleted when any underlying telegram message id is deleted' do
      channel = create(:channel_telegram_personal)
      contact = create(:contact, account: channel.account)
      contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '23')
      conversation = create(
        :conversation,
        account: channel.account,
        inbox: channel.inbox,
        contact: contact,
        contact_inbox: contact_inbox
      )
      message = create(
        :message,
        :with_attachment,
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        source_id: '101',
        content: 'album caption',
        content_attributes: { 'telegram_message_ids' => %w[101 102], 'grouped_id' => '9001' }
      )

      described_class.new(
        inbox: channel.inbox,
        params: { message_ids: ['102'] }
      ).perform

      expect(message.reload.content_attributes['deleted']).to eq(true)
      expect(message.content).to eq(I18n.t('conversations.messages.deleted'))
      expect(message.attachments.count).to eq(0)
    end
  end
end
