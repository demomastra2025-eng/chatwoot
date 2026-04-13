require 'rails_helper'

RSpec.describe TelegramPersonal::IncomingMessageService do
  before do
    stub_request(:get, 'https://chatwoot-assets.local/sample.png').to_return(
      status: 200,
      body: File.read(Rails.root.join('spec/assets/sample.png')),
      headers: { 'Content-Type' => 'image/png' }
    )
    stub_request(:get, 'https://chatwoot-assets.local/sample.mov').to_return(
      status: 200,
      body: File.read(Rails.root.join('spec/assets/sample.mov')),
      headers: { 'Content-Type' => 'video/mp4' }
    )
  end

  let(:channel) { create(:channel_telegram_personal) }

  describe '#perform' do
    it 'creates a single message for incoming albums with multiple attachments' do
      described_class.new(
        inbox: channel.inbox,
        params: {
          message_id: '101',
          telegram_message_ids: %w[101 102],
          grouped_id: '9001',
          chat_id: '23',
          peer_user_id: '23',
          sender_id: '23',
          chat_type: 'private',
          text: 'album caption',
          first_name: 'Sojan',
          last_name: 'Jose',
          username: 'sojan',
          language_code: 'en',
          attachments: [
            { kind: 'photo', url: 'https://chatwoot-assets.local/sample.png', filename: 'sample.png', content_type: 'image/png' },
            { kind: 'video', url: 'https://chatwoot-assets.local/sample.mov', filename: 'sample.mov', content_type: 'video/mp4' }
          ]
        }
      ).perform

      message = channel.inbox.messages.last
      expect(channel.inbox.messages.count).to eq(1)
      expect(message.source_id).to eq('101')
      expect(message.content).to eq('album caption')
      expect(message.attachments.pluck(:file_type)).to match_array(%w[image video])
      expect(message.content_attributes['grouped_id']).to eq('9001')
      expect(message.content_attributes['telegram_message_ids']).to eq(%w[101 102])
    end

    it 'stores forwarded metadata and reactions for telegram messages' do
      described_class.new(
        inbox: channel.inbox,
        params: {
          message_id: '301',
          chat_id: '23',
          peer_user_id: '23',
          sender_id: '23',
          chat_type: 'private',
          text: 'forwarded hello',
          first_name: 'Sojan',
          username: 'sojan',
          reactions: {
            total_count: 2,
            results: [
              { reaction: { type: 'emoji', emoji: '👍' }, count: 2 }
            ]
          },
          forwarded_from: {
            from_id: { type: 'user', id: '99' },
            from_name: 'Origin User'
          }
        }
      ).perform

      message = channel.inbox.messages.last
      expect(message.content_attributes['telegram_reactions']).to eq(
        'total_count' => 2,
        'results' => [{ 'reaction' => { 'type' => 'emoji', 'emoji' => '👍' }, 'count' => 2 }]
      )
      expect(message.content_attributes['telegram_forwarded_from']).to eq(
        'from_id' => { 'type' => 'user', 'id' => '99' },
        'from_name' => 'Origin User'
      )
    end

    it 'marks imported history messages and preserves provider timestamp' do
      described_class.new(
        inbox: channel.inbox,
        params: {
          message_id: '401',
          message_created_at: '2026-04-08T10:15:30Z',
          imported_history: true,
          chat_id: '23',
          peer_user_id: '23',
          sender_id: '23',
          chat_type: 'private',
          text: 'history hello',
          first_name: 'Sojan',
          username: 'sojan'
        }
      ).perform

      message = channel.inbox.messages.last

      expect(message.content_attributes['imported_history']).to eq(true)
      expect(message.content_attributes['external_created_at']).to eq('2026-04-08T10:15:30Z')
      expect(message.created_at.iso8601).to eq('2026-04-08T10:15:30Z')
    end

    it 'keeps imported incoming and outgoing history in the same conversation for one peer' do
      described_class.new(
        inbox: channel.inbox,
        params: {
          message_id: '410',
          message_created_at: '2026-04-08T10:15:30Z',
          imported_history: true,
          chat_id: '23',
          peer_user_id: '23',
          sender_id: '23',
          chat_type: 'private',
          text: 'incoming history',
          first_name: 'Sojan',
          username: 'sojan'
        }
      ).perform

      described_class.new(
        inbox: channel.inbox,
        params: {
          message_id: '411',
          message_created_at: '2026-04-08T10:16:30Z',
          imported_history: true,
          outgoing_echo: true,
          chat_id: '23',
          peer_user_id: '23',
          sender_id: '999',
          chat_type: 'private',
          text: 'outgoing history',
          first_name: 'Sojan',
          username: 'sojan'
        }
      ).perform

      expect(channel.inbox.conversations.count).to eq(1)

      conversation = channel.inbox.conversations.last
      messages = conversation.messages.reorder(created_at: :asc)

      expect(conversation.contact_inbox.source_id).to eq('23')
      expect(messages.map(&:message_type)).to eq(%w[incoming outgoing])
      expect(messages.map(&:content)).to eq(['incoming history', 'outgoing history'])
      expect(messages.last.sender).to be_nil
    end

    it 'stores outgoing echoes without sending them back to telegram' do
      expect do
        described_class.new(
          inbox: channel.inbox,
          params: {
            message_id: '501',
            chat_id: '23',
            peer_user_id: '23',
            sender_id: '23',
            chat_type: 'private',
            text: 'sent from telegram',
            outgoing_echo: true,
            first_name: 'Sojan',
            username: 'sojan'
          }
        ).perform
      end.not_to have_enqueued_job(SendReplyJob)

      message = channel.inbox.messages.last
      expect(message).to be_outgoing
      expect(message.sender).to be_nil
      expect(message.content_attributes['external_echo']).to eq(true)
    end

    it 'keeps history messages when attachment downloads are unavailable' do
      allow(Down).to receive(:download).and_raise(StandardError, 'expired media URL')

      expect do
        described_class.new(
          inbox: channel.inbox,
          params: {
            message_id: '601',
            imported_history: true,
            chat_id: '23',
            peer_user_id: '23',
            sender_id: '23',
            chat_type: 'private',
            first_name: 'Sojan',
            username: 'sojan',
            attachments: [
              { kind: 'audio', url: 'https://chatwoot-assets.local/expired.ogg', filename: 'expired.ogg', content_type: 'audio/ogg' }
            ]
          }
        ).perform
      end.not_to raise_error

      message = channel.inbox.messages.last
      expect(message.content).to eq('[Attachment]')
      expect(message.attachments).to be_empty
      expect(message.content_attributes['telegram_unavailable_attachments']).to include(
        hash_including(
          'kind' => 'audio',
          'filename' => 'expired.ogg',
          'content_type' => 'audio/ogg',
          'url' => 'https://chatwoot-assets.local/expired.ogg',
          'error' => 'StandardError'
        )
      )
    end
  end
end
