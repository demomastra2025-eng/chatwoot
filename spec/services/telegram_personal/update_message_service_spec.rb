require 'rails_helper'

RSpec.describe TelegramPersonal::UpdateMessageService do
  describe '#perform' do
    context 'when Telegram resends message content with reaction snapshots' do
      let(:channel) { create(:channel_telegram_personal) }
      let(:contact) { create(:contact, account: channel.account) }
      let(:contact_inbox) { create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '23') }
      let(:conversation) do
        create(:conversation, account: channel.account, inbox: channel.inbox, contact: contact, contact_inbox: contact_inbox)
      end
      let!(:message) do
        create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation,
                         message_type: :outgoing, source_id: '101', content: 'Original message')
      end
      let(:reactions) { { total_count: 1, results: [{ reaction: { type: 'emoji', emoji: '👍' }, count: 1 }] } }

      def update_message(**attributes)
        described_class.new(inbox: channel.inbox, params: { message_id: '101', chat_id: '23', **attributes }).perform
      end

      it 'updates reactions without marking unchanged text as edited' do
        update_message(text: message.content, caption: message.content, reactions: reactions)

        expect(message.reload.content).to eq('Original message')
        expect(message.content_attributes['edited']).to be_nil
        expect(message.content_attributes.dig('telegram_reactions', 'total_count')).to eq(1)
      end

      it 'does not mark an unchanged media caption as edited' do
        update_message(caption: message.content, reactions: reactions)

        expect(message.reload.content_attributes['edited']).to be_nil
      end

      it 'preserves a real edit marker when a reaction later changes' do
        message.update!(content_attributes: { edited: true })
        update_message(text: message.content, reactions: reactions)

        expect(message.reload.content_attributes['edited']).to be(true)
      end

      it 'marks a changed body as edited even when a reaction arrives in the same update' do
        update_message(text: 'Corrected message', reactions: reactions)

        expect(message.reload.content).to eq('Corrected message')
        expect(message.content_attributes['edited']).to be(true)
        expect(message.content_attributes.dig('telegram_reactions', 'total_count')).to eq(1)
      end

      it 'clears reactions idempotently without creating an edit' do
        update_message(text: message.content, reactions: reactions)
        update_message(text: message.content, reactions: { total_count: 0, results: [] })
        timestamp = message.reload.updated_at
        update_message(text: message.content, reactions: { total_count: 0, results: [] })

        expect(message.reload.content_attributes['edited']).to be_nil
        expect(message.content_attributes['telegram_reactions']).to eq('total_count' => 0, 'results' => [])
        expect(message.updated_at).to eq(timestamp)
      end
    end

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
