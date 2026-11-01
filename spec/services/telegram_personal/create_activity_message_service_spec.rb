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
      expect(
        Conversations::CallsOnlyScope.conversation_has_calls?(channel.inbox.conversations.last)
      ).to be(false)
    end

    it 'marks native/synced Telegram voice and video call activity conversations for CallsOnlyScope' do
      described_class.new(
        inbox: channel.inbox,
        params: {
          message_id: '901',
          chat_id: '45',
          peer_user_id: '45',
          sender_id: '45',
          first_name: 'Aidar',
          activity_type: 'missed_voice_call'
        }
      ).perform

      conversation = channel.inbox.conversations.last.reload
      expect(conversation.additional_attributes).to include(
        'call_provider' => 'telegram_personal',
        'call_status' => 'missed'
      )
      expect(Conversations::CallsOnlyScope.conversation_has_calls?(conversation)).to be(true)
      expect(
        Conversations::CallsOnlyScope.apply(
          channel.inbox.account.conversations,
          account_id: channel.inbox.account_id
        ).pluck(:id)
      ).to include(conversation.id)
    end

    it 'does not overwrite active ringing or in-progress call_status when syncing call activity' do
      described_class.new(
        inbox: channel.inbox,
        params: {
          message_id: '902',
          chat_id: '46',
          peer_user_id: '46',
          sender_id: '46',
          first_name: 'Dana',
          activity_type: 'contact_joined'
        }
      ).perform

      conversation = channel.inbox.conversations.last
      conversation.update!(
        additional_attributes: conversation.additional_attributes.merge('call_status' => 'in-progress')
      )

      described_class.new(
        inbox: channel.inbox,
        params: {
          message_id: '903',
          chat_id: '46',
          peer_user_id: '46',
          sender_id: '46',
          first_name: 'Dana',
          activity_type: 'completed_video_call',
          activity_params: { duration_seconds: 35 }
        }
      ).perform

      expect(conversation.reload.additional_attributes).to include(
        'call_provider' => 'telegram_personal',
        'call_status' => 'in-progress'
      )
    end
  end
end
