require 'rails_helper'

RSpec.describe Messages::ReactionService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, name: 'Арайлым') }

  describe 'channel and message validation' do
    let(:inbox) { create(:inbox, account: account) }
    let(:conversation) { create(:conversation, account: account, inbox: inbox) }
    let(:message) { create(:message, account: account, inbox: inbox, conversation: conversation, source_id: 'msg-1', content: 'Привет!') }

    it 'rejects reactions on channels that do not support reactions (e.g. WebWidget/Email/SMS)' do
      expect do
        described_class.new(message: message, user: user, emoji: '❤️').perform
      end.to raise_error(Messages::ReactionService::Error, 'Reactions are not supported for this channel')
    end

    it 'rejects reactions on activity, private, or deleted messages' do
      tg_channel = create(:channel_telegram, account: account)
      tg_conv = create(:conversation, account: account, inbox: tg_channel.inbox, additional_attributes: { 'chat_id' => '123' })

      activity_msg = create(:message, account: account, inbox: tg_channel.inbox, conversation: tg_conv, message_type: :activity, content: 'Joined')
      expect do
        described_class.new(message: activity_msg, user: user, emoji: '👍').perform
      end.to raise_error(Messages::ReactionService::Error, 'Cannot react to activity messages')

      private_msg = create(:message, account: account, inbox: tg_channel.inbox, conversation: tg_conv, private: true, source_id: '11', content: 'Note')
      expect do
        described_class.new(message: private_msg, user: user, emoji: '👍').perform
      end.to raise_error(Messages::ReactionService::Error, 'Cannot react to private notes')

      deleted_msg = create(:message, account: account, inbox: tg_channel.inbox, conversation: tg_conv, source_id: '12', content_attributes: { deleted: true })
      expect do
        described_class.new(message: deleted_msg, user: user, emoji: '👍').perform
      end.to raise_error(Messages::ReactionService::Error, 'Cannot react to deleted messages')

      unsynced_msg = create(:message, account: account, inbox: tg_channel.inbox, conversation: tg_conv, source_id: nil, content: 'Pending')
      expect do
        described_class.new(message: unsynced_msg, user: user, emoji: '👍').perform
      end.to raise_error(Messages::ReactionService::Error, 'Cannot react to a message without external source_id')
    end

    it 'rejects invalid multi-character or non-emoji reactions' do
      tg_channel = create(:channel_telegram, account: account)
      tg_conv = create(:conversation, account: account, inbox: tg_channel.inbox, additional_attributes: { 'chat_id' => '123' })
      tg_msg = create(:message, account: account, inbox: tg_channel.inbox, conversation: tg_conv, source_id: '99', content: 'Hi')

      expect do
        described_class.new(message: tg_msg, user: user, emoji: 'not-an-emoji').perform
      end.to raise_error(Messages::ReactionService::Error, 'Reaction must contain a single valid emoji')

      expect do
        described_class.new(message: tg_msg, user: user, emoji: '👍❤️').perform
      end.to raise_error(Messages::ReactionService::Error, 'Reaction must contain a single valid emoji')
    end
  end

  describe '#perform on WhatsApp Cloud channel' do
    let(:channel) do
      create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
    end
    let(:contact) { create(:contact, account: account, phone_number: '+77015551122') }
    let(:contact_inbox) { create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '77015551122') }
    let(:conversation) { create(:conversation, account: account, inbox: channel.inbox, contact: contact, contact_inbox: contact_inbox) }
    let(:message) do
      create(:message, account: account, inbox: channel.inbox, conversation: conversation, source_id: 'wamid.target123', content: 'Запись подтверждена')
    end

    it 'dispatches reaction to WhatsApp Cloud API, updates whatsapp_reactions, and toggles off when repeated' do
      stub = stub_request(:post, "https://graph.facebook.com/v25.0/#{channel.provider_config['phone_number_id']}/messages")
             .to_return(
               status: 200,
               body: { messages: [{ id: 'wamid.reaction1' }] }.to_json,
               headers: { 'Content-Type' => 'application/json' }
             )

      described_class.new(message: message, user: user, emoji: '🔥').perform

      expect(stub).to have_been_requested.once
      expect(message.reload.content_attributes.dig('whatsapp_reactions', 'business')).to include(
        'emoji' => '🔥',
        'user_id' => user.id,
        'user_name' => 'Арайлым'
      )

      # Toggling the same emoji removes it
      described_class.new(message: message, user: user, emoji: '🔥').perform
      expect(stub).to have_been_requested.twice
      expect(message.reload.content_attributes.dig('whatsapp_reactions', 'business')).to be_nil
    end
  end

  describe '#perform on Telegram Bot channel' do
    let(:channel) { create(:channel_telegram, account: account) }
    let(:conversation) do
      create(:conversation, account: account, inbox: channel.inbox, additional_attributes: { 'chat_id' => '987654' })
    end
    let(:message) do
      create(:message, account: account, inbox: channel.inbox, conversation: conversation, source_id: '42', content: 'Тест')
    end

    it 'calls setMessageReaction on Telegram API and updates telegram_reactions' do
      stub = stub_request(:post, "https://api.telegram.org/bot#{channel.bot_token}/setMessageReaction")
             .to_return(
               status: 200,
               body: { ok: true, result: true }.to_json,
               headers: { 'Content-Type' => 'application/json' }
             )

      described_class.new(message: message, user: user, emoji: '👍').perform

      expect(stub).to have_been_requested
      expect(message.reload.content_attributes['telegram_reactions']).to eq(
        'total_count' => 1,
        'results' => [
          {
            'reaction' => { 'type' => 'emoji', 'emoji' => '👍' },
            'count' => 1,
            'chosen' => true
          }
        ]
      )
    end
  end
end
