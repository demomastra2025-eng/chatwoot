require 'rails_helper'

RSpec.describe TelegramPersonal::UpdateMessageService do
  describe '#perform' do
    it 'updates album messages found by telegram_message_ids' do
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
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        source_id: '101',
        content: 'old caption',
        content_attributes: { 'telegram_message_ids' => %w[101 102], 'grouped_id' => '9001' }
      )

      described_class.new(
        inbox: channel.inbox,
        params: { message_id: '102', caption: 'updated caption' }
      ).perform

      expect(message.reload.content).to eq('updated caption')
      expect(message.content_attributes['edited']).to eq(true)
    end

    it 'refreshes reactions and forwarded metadata on update' do
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
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        source_id: '101',
        content: 'old text'
      )

      described_class.new(
        inbox: channel.inbox,
        params: {
          message_id: '101',
          text: 'edited text',
          reactions: { total_count: 1, results: [{ reaction: { type: 'emoji', emoji: '🔥' }, count: 1 }] },
          forwarded_from: { from_name: 'Origin User' }
        }
      ).perform

      expect(message.reload.content).to eq('edited text')
      expect(message.content_attributes['edited']).to eq(true)
      expect(message.content_attributes['telegram_reactions']).to eq(
        'total_count' => 1,
        'results' => [{ 'reaction' => { 'type' => 'emoji', 'emoji' => '🔥' }, 'count' => 1 }]
      )
      expect(message.content_attributes['telegram_forwarded_from']).to eq(
        'from_name' => 'Origin User'
      )
    end

    it 'does not mark reaction-only updates as edited and clears reaction snapshots' do
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
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        source_id: '101',
        content: 'stable text',
        content_attributes: {
          'telegram_reactions' => {
            'total_count' => 1,
            'results' => [{ 'reaction' => { 'type' => 'emoji', 'emoji' => '🔥' }, 'count' => 1 }]
          }
        }
      )

      described_class.new(
        inbox: channel.inbox,
        params: {
          message_id: '101',
          reactions: { total_count: 0, results: [] }
        }
      ).perform

      expect(message.reload.content).to eq('stable text')
      expect(message.content_attributes['edited']).to be_nil
      expect(message.content_attributes['telegram_reactions']).to eq(
        'total_count' => 0,
        'results' => []
      )
    end
  end
end
