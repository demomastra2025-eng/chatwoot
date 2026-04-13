require 'rails_helper'

RSpec.describe Messages::UpdateContentService do
  describe '#perform' do
    it 'edits telegram bot outgoing messages through the channel' do
      channel = create(:channel_telegram)
      conversation = create(
        :conversation,
        account: channel.account,
        inbox: channel.inbox,
        additional_attributes: { 'chat_id' => '123', 'business_connection_id' => 'biz-1' }
      )
      message = create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        message_type: :outgoing,
        source_id: '202',
        content: 'old text'
      )

      expect(channel).to receive(:update_message).with(message: message, content: 'new text')

      described_class.new(message: message, content: 'new text').perform

      expect(message.reload.content).to eq('new text')
      expect(message.content_attributes['edited']).to eq(true)
    end

    it 'edits telegram personal outgoing messages through the channel' do
      channel = create(:channel_telegram_personal)
      conversation = create(:conversation, account: channel.account, inbox: channel.inbox)
      message = create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        message_type: :outgoing,
        source_id: '101',
        content: 'old text'
      )

      expect(channel).to receive(:update_message).with(message: message, content: 'new text')

      described_class.new(message: message, content: 'new text').perform

      expect(message.reload.content).to eq('new text')
      expect(message.content_attributes['edited']).to eq(true)
    end
  end
end
