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

      # Provider ordering/hidden/same-body/empty-caption guarantees from 9916e0f43e are deferred.
      it 'applies new producer fields through the same arrival-order reducer without a watermark' do
        update_message(text: 'Latest provider edit', message_edited_at: '2026-11-02T02:00:00Z', message_edit_hidden: false)
        update_message(text: 'Earlier provider edit arriving last', message_edited_at: '2026-11-02T01:00:00Z', message_edit_hidden: true)

        expect(message.reload.content).to eq('Earlier provider edit arriving last')
        expect(message.content_attributes['edited']).to be(true)
        expect(message.content_attributes).not_to have_key('telegram_message_edited_at')
      end

      it 'does not mark a same-body provider edit under the legacy contract' do
        update_message(text: message.content, message_edited_at: '2026-11-02T01:00:00Z', message_edit_hidden: false)

        expect(message.reload.content_attributes['edited']).to be_nil
      end

      it 'retains the existing body when an empty caption arrives' do
        update_message(text: nil, caption: '', message_edited_at: '2026-11-02T01:00:00Z', message_edit_hidden: false)

        expect(message.reload.content).to eq('Original message')
        expect(message.content_attributes['edited']).to be_nil
      end

      it 'does not interpret unused provider metadata as an alternate update protocol' do
        update_message(text: 'Corrected message', message_edited_at: 'not-a-timestamp', message_edit_hidden: 'false')

        expect(message.reload.content).to eq('Corrected message')
        expect(message.content_attributes['edited']).to be(true)
      end

      {
        '**Original** message' => '<strong>Original</strong> message',
        '`**literal**`' => '<code>literal</code>',
        '[Link](https://example.test)' => '<a href="https://example.test">Link</a>',
        '\\*\\*literal\\*\\*' => 'literal'
      }.each do |original, snapshot|
        it "documents legacy snapshot replacement for #{original.inspect}" do
          message.update!(content: original)
          update_message(text: snapshot, reactions: reactions)

          expect(message.reload.content).to eq(snapshot)
          expect(message.content_attributes['edited']).to be(true)
        end
      end

      it 'documents legacy replacement of a formatted attachment caption' do
        message.update!(content: '**Original** caption')
        message.attachments.create!(account: channel.account, file_type: :image, external_url: 'https://example.test/avatar.png')
        update_message(caption: '<strong>Original</strong> caption', reactions: reactions)

        expect(message.reload.content).to eq('<strong>Original</strong> caption')
        expect(message.content_attributes['edited']).to be(true)
      end

      it 'performs an already queued full legacy callback without edit metadata' do
        Channels::TelegramPersonal::ProcessWebhookEventJob.perform_now(
          channel.id, { event: 'message.updated', telegram_personal: { data: { message_id: '101', chat_id: '23', text: 'Queued edit' } } }
        )

        expect(message.reload.content).to eq('Queued edit')
        expect(message.content_attributes['edited']).to be(true)
      end

      it 'does not update another chat even when the provider message id matches' do
        update_message(chat_id: '24', text: 'Wrong chat')

        expect(message.reload.content).to eq('Original message')
      end

      it 'does not update a matching message through another inbox' do
        other_channel = create(:channel_telegram_personal)
        described_class.new(inbox: other_channel.inbox, params: { message_id: '101', text: 'Wrong inbox' }).perform

        expect(message.reload.content).to eq('Original message')
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
