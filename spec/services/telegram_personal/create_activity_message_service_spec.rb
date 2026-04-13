require 'rails_helper'

RSpec.describe TelegramPersonal::CreateActivityMessageService do
  let(:channel) { create(:channel_telegram_personal) }

  around do |example|
    I18n.with_locale(:en) { example.run }
  end

  describe '#perform' do
    it 'creates an activity message for telegram service events' do
      described_class.new(
        inbox: channel.inbox,
        params: {
          message_id: '501',
          chat_id: '23',
          peer_user_id: '23',
          sender_id: '23',
          first_name: 'Sojan',
          last_name: 'Jose',
          username: 'sojan',
          activity_type: 'contact_joined'
        }
      ).perform

      conversation = channel.inbox.conversations.last
      message = conversation.messages.last

      expect(channel.inbox.conversations.count).to eq(1)
      expect(message.activity?).to be(true)
      expect(message.source_id).to eq('501')
      expect(message.content).to eq('Sojan Jose joined Telegram')
      expect(message.content_attributes['telegram_activity_type']).to eq('contact_joined')
      expect(conversation.contact_inbox.source_id).to eq('23')
    end

    it 'deduplicates activity events by provider message id' do
      params = {
        message_id: '777',
        chat_id: '23',
        peer_user_id: '23',
        sender_id: '23',
        first_name: 'Sojan',
        activity_type: 'history_cleared'
      }

      described_class.new(inbox: channel.inbox, params: params).perform
      described_class.new(inbox: channel.inbox, params: params).perform

      expect(channel.inbox.messages.where(source_id: '777').count).to eq(1)
      expect(channel.inbox.messages.activity.last.content).to eq('Telegram chat history was cleared')
    end
  end
end
