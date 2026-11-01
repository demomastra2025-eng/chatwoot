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
        described_class.new(inbox: channel.inbox, params: {
                              message_id: '101', chat_id: '23', message_edited_at: nil, message_edit_hidden: false, **attributes
                            }).perform
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
        update_message(text: 'Corrected message', reactions: reactions, message_edited_at: '2026-11-02T01:00:00Z')

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

      it 'keeps outgoing Markdown on a full reaction snapshot containing rendered bold text' do
        message.update!(content: '**Original** message')
        expect(message.outgoing_content).to eq('<strong>Original</strong> message')

        update_message(text: message.outgoing_content, reactions: reactions)

        expect(message.reload.content).to eq('**Original** message')
        expect(message.content_attributes['edited']).to be_nil
      end

      it 'keeps a formatted attachment caption on an unedited provider snapshot' do
        message.update!(content: '**Original** caption')
        message.attachments.create!(account: channel.account, file_type: :image, external_url: 'https://example.test/avatar.png')

        update_message(caption: message.outgoing_content, reactions: reactions)

        expect(message.reload.content).to eq('**Original** caption')
        expect(message.content_attributes['edited']).to be_nil
      end

      it 'uses metadata when the SDK parses markup inside a rendered inline code span' do
        message.update!(content: '`**literal**`')
        expect(message.outgoing_content).to eq('<code>**literal**</code>')
        # Actual Telethon default Markdown parser output; see the SDK projection probe.
        update_message(text: '<code>literal</code>', reactions: reactions)

        expect(message.reload.content).to eq('`**literal**`')
        expect(message.content_attributes['edited']).to be_nil
      end

      it 'keeps a stored Markdown link on an unedited full provider snapshot' do
        message.update!(content: '[Link](https://example.test)')

        update_message(text: message.outgoing_content, reactions: reactions)

        expect(message.reload.content).to eq('[Link](https://example.test)')
        expect(message.content_attributes['edited']).to be_nil
      end

      it 'keeps an escaped Markdown literal when the SDK parses the outgoing escapes' do
        message.update!(content: '\\*\\*literal\\*\\*')
        expect(message.outgoing_content).to eq('**literal**')
        update_message(text: 'literal', reactions: reactions)

        expect(message.reload.content).to eq('\\*\\*literal\\*\\*')
        expect(message.content_attributes['edited']).to be_nil
      end

      it 'preserves a real provider edit even when the raw body is unchanged' do
        update_message(text: message.content, message_edited_at: '2026-11-02T01:00:00Z')

        expect(message.reload.content_attributes['edited']).to be(true)
        expect(message.content_attributes['telegram_message_edited_at']).to eq('2026-11-02T01:00:00Z')
      end

      it 'applies a hidden provider edit without showing an edit marker' do
        update_message(text: 'Hidden edit', message_edited_at: '2026-11-02T01:00:00Z', message_edit_hidden: true)

        expect(message.reload.content).to eq('Hidden edit')
        expect(message.content_attributes['edited']).to be(false)
      end

      it 'does not overwrite a newer body or edit visibility with an older provider edit' do
        update_message(text: 'Latest text', message_edited_at: '2026-11-02T02:00:00Z')
        update_message(text: 'Old text', message_edited_at: '2026-11-02T01:00:00Z', message_edit_hidden: true)

        expect(message.reload.content).to eq('Latest text')
        expect(message.content_attributes['edited']).to be(true)
        expect(message.content_attributes['telegram_message_edited_at']).to eq('2026-11-02T02:00:00Z')
      end

      it 'retains a second genuine edit within the provider timestamp resolution' do
        update_message(text: 'First edit', message_edited_at: '2026-11-02T01:00:00Z')
        update_message(text: 'Second edit', message_edited_at: '2026-11-02T01:00:00Z')

        expect(message.reload.content).to eq('Second edit')
      end

      it 'clears an attachment caption on an explicit provider edit' do
        message.attachments.create!(account: channel.account, file_type: :image, external_url: 'https://example.test/avatar.png')
        update_message(text: nil, caption: nil, message_edited_at: '2026-11-02T01:00:00Z')

        expect(message.reload.content).to eq('')
        expect(message.content_attributes['edited']).to be(true)
      end

      it 'rejects missing provider fields instead of guessing whether a legacy full callback is an edit' do
        expect do
          described_class.new(inbox: channel.inbox, params: { message_id: '101', text: 'Potential real edit' }).perform
        end.to raise_error(described_class::InvalidEditMetadataError)

        expect(message.reload.content).to eq('Original message')
      end

      it 'rejects a malformed timestamp or non-boolean hidden flag' do
        expect do
          update_message(text: 'Potential real edit', message_edited_at: 'not-a-timestamp')
        end.to raise_error(described_class::InvalidEditMetadataError)
        expect do
          update_message(text: 'Potential real edit', message_edit_hidden: 'false')
        end.to raise_error(described_class::InvalidEditMetadataError)

        expect(message.reload.content).to eq('Original message')
      end

      it 'retains legacy queued full callbacks as explicit failed work instead of silently losing real edits' do
        expect do
          Channels::TelegramPersonal::ProcessWebhookEventJob.perform_now(
            channel.id, { event: 'message.updated', telegram_personal: { data: { message_id: '101', text: 'Real edit' } } }
          )
        end.to raise_error(described_class::InvalidEditMetadataError)

        expect(message.reload.content).to eq('Original message')
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
        params: { message_id: '102', caption: 'updated caption', message_edited_at: '2026-11-02T01:00:00Z', message_edit_hidden: false }
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
          message_edited_at: '2026-11-02T01:00:00Z',
          message_edit_hidden: false,
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
