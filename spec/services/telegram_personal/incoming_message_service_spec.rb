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
      Time.use_zone('Australia/Sydney') do
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
        expect(message.created_at.utc.iso8601).to eq('2026-04-08T10:15:30Z')
      end
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

    it 'enriches an incomplete media-only history message without duplicates' do
      base_params = {
        message_id: '701',
        imported_history: true,
        chat_id: '23',
        peer_user_id: '23',
        sender_id: '23',
        chat_type: 'private',
        first_name: 'Sojan',
        username: 'sojan'
      }
      described_class.new(
        inbox: channel.inbox,
        params: base_params.merge(
          history_media_incomplete: true,
          history_media_skipped_message_ids: ['701']
        )
      ).perform

      message = channel.inbox.messages.last
      expect(message.content).to eq('[Attachment]')
      expect(message.attachments).to be_empty
      expect(message.content_attributes['telegram_history_media_incomplete']).to be(true)

      replay_params = base_params.merge(
        history_media_incomplete: false,
        attachments: [
          {
            kind: 'photo',
            url: 'https://chatwoot-assets.local/sample.png',
            filename: 'sample.png',
            content_type: 'image/png',
            telegram_message_id: '701'
          }
        ]
      )
      described_class.new(inbox: channel.inbox, params: replay_params).perform
      described_class.new(inbox: channel.inbox, params: replay_params).perform

      message.reload
      expect(message.content).to eq('')
      expect(message.attachments.count).to eq(1)
      expect(message.attachments.first.meta['telegram_message_id']).to eq('701')
      expect(message.content_attributes).not_to include(
        'telegram_history_media_incomplete',
        'telegram_history_media_skipped_message_ids'
      )
    end

    it 'enriches only the missing attachment in a partial history album' do
      base_params = {
        message_id: '801',
        telegram_message_ids: %w[801 802],
        grouped_id: '9801',
        imported_history: true,
        chat_id: '23',
        peer_user_id: '23',
        sender_id: '23',
        chat_type: 'private',
        text: 'album caption',
        first_name: 'Sojan',
        username: 'sojan'
      }
      first_attachment = {
        kind: 'photo',
        url: 'https://chatwoot-assets.local/sample.png',
        filename: 'sample.png',
        content_type: 'image/png',
        telegram_message_id: '801'
      }
      second_attachment = {
        kind: 'video',
        url: 'https://chatwoot-assets.local/sample.mov',
        filename: 'sample.mov',
        content_type: 'video/mp4',
        telegram_message_id: '802'
      }
      described_class.new(
        inbox: channel.inbox,
        params: base_params.merge(
          history_media_incomplete: true,
          history_media_skipped_message_ids: ['802'],
          attachments: [first_attachment]
        )
      ).perform

      replay_params = base_params.merge(
        history_media_incomplete: false,
        attachments: [first_attachment, second_attachment]
      )
      described_class.new(inbox: channel.inbox, params: replay_params).perform
      described_class.new(inbox: channel.inbox, params: replay_params).perform

      message = channel.inbox.messages.last
      expect(channel.inbox.messages.count).to eq(1)
      expect(message.attachments.count).to eq(2)
      expect(message.attachments.map { |attachment| attachment.meta['telegram_message_id'] }).to match_array(%w[801 802])
      expect(message.content_attributes).not_to have_key('telegram_history_media_incomplete')
    end

    it 'keeps the incomplete marker when media enrichment download fails' do
      base_params = {
        message_id: '901',
        imported_history: true,
        chat_id: '23',
        peer_user_id: '23',
        sender_id: '23',
        chat_type: 'private',
        first_name: 'Sojan',
        username: 'sojan'
      }
      described_class.new(
        inbox: channel.inbox,
        params: base_params.merge(
          history_media_incomplete: true,
          history_media_skipped_message_ids: ['901']
        )
      ).perform

      allow(Down).to receive(:download).and_raise(StandardError, 'temporary media failure')
      described_class.new(
        inbox: channel.inbox,
        params: base_params.merge(
          history_media_incomplete: false,
          attachments: [
            {
              kind: 'photo',
              url: 'https://chatwoot-assets.local/retry.png',
              filename: 'retry.png',
              content_type: 'image/png',
              telegram_message_id: '901'
            }
          ]
        )
      ).perform

      message = channel.inbox.messages.last
      expect(message.attachments).to be_empty
      expect(message.content_attributes['telegram_history_media_incomplete']).to be(true)
      expect(message.content_attributes['telegram_unavailable_attachments']).to include(
        hash_including('filename' => 'retry.png', 'error' => 'StandardError')
      )
    end

    it 'namespaces supergroup source_ids so two supergroups and private chats never collide on message_id' do
      channel.update!(runtime_state: channel.runtime_state_payload.merge('sync_groups' => true))

      described_class.new(
        inbox: channel.inbox,
        params: {
          message_id: '42',
          chat_id: '6002671687',
          peer_user_id: '6002671687',
          sender_id: '6002671687',
          chat_type: 'private',
          is_self: true,
          text: 'saved note'
        }
      ).perform
      described_class.new(
        inbox: channel.inbox,
        params: {
          message_id: '42',
          chat_id: '-100111',
          chat_type: 'supergroup',
          chat_title: 'Group A',
          sender_id: '55',
          text: 'group a msg 42'
        }
      ).perform
      described_class.new(
        inbox: channel.inbox,
        params: {
          message_id: '42',
          chat_id: '-100222',
          chat_type: 'supergroup',
          chat_title: 'Group B',
          sender_id: '66',
          text: 'group b msg 42'
        }
      ).perform

      expect(channel.inbox.messages.pluck(:source_id, :content)).to contain_exactly(
        ['42', 'saved note'],
        ['tg_group:-100111:42', 'group a msg 42'],
        ['tg_group:-100222:42', 'group b msg 42']
      )
    end

    it 'formats group reply_to_message_id with tg_group prefix and reconciles pending group reply echoes' do
      channel = create(:channel_telegram_personal, runtime_state: { 'sync_groups' => true })
      group_contact = create(:contact, account: channel.account, name: 'Clinic Group')
      contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: group_contact, source_id: '-100777')
      conversation = create(
        :conversation,
        account: channel.account,
        inbox: channel.inbox,
        contact: group_contact,
        contact_inbox: contact_inbox,
        additional_attributes: { 'chat_id' => '-100777', 'chat_type' => 'supergroup' }
      )
      parent_msg = create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        source_id: 'tg_group:-100777:10',
        content: 'Parent question'
      )
      pending_reply = create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        message_type: :outgoing,
        sender: nil,
        source_id: nil,
        content: 'Agent reply in group',
        content_attributes: { 'in_reply_to' => parent_msg.id }
      )

      described_class.new(
        inbox: channel.inbox,
        params: {
          message_id: '11',
          chat_id: '-100777',
          chat_type: 'supergroup',
          chat_title: 'Clinic Group',
          outgoing_echo: true,
          reply_to_message_id: '10',
          text: 'Agent reply in group'
        }
      ).perform

      expect(pending_reply.reload.source_id).to eq('tg_group:-100777:11')
      expect(pending_reply.content_attributes['in_reply_to']).to eq(parent_msg.id)
      expect(conversation.messages.count).to eq(2)
    end

    it 'rekeys legacy unprefixed group messages on collision so 1:1 private messages with the same id are imported' do
      channel = create(:channel_telegram_personal, runtime_state: { 'sync_groups' => true })
      group_contact = create(:contact, account: channel.account, name: 'Legacy Group')
      group_ci = create(:contact_inbox, inbox: channel.inbox, contact: group_contact, source_id: '-100888')
      group_conv = create(
        :conversation,
        account: channel.account,
        inbox: channel.inbox,
        contact: group_contact,
        contact_inbox: group_ci,
        additional_attributes: { 'chat_id' => '-100888', 'chat_type' => 'supergroup' }
      )
      legacy_group_msg = create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: group_conv,
        source_id: '55',
        content: 'old unprefixed group msg'
      )

      described_class.new(
        inbox: channel.inbox,
        params: {
          message_id: '55',
          peer_user_id: '6002671687',
          chat_id: '6002671687',
          chat_type: 'private',
          is_self: true,
          outgoing_echo: true,
          imported_history: true,
          text: 'saved note 55'
        }
      ).perform

      expect(legacy_group_msg.reload.source_id).to eq('tg_group:-100888:55')
      expect(channel.inbox.messages.find_by(source_id: '55')&.content).to eq('saved note 55')
    end
  end
end
