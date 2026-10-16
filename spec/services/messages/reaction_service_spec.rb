require 'rails_helper'

RSpec.describe Messages::ReactionService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, name: 'Арайлым') }

  describe '#perform on internal/web widget messages' do
    let(:inbox) { create(:inbox, account: account) }
    let(:conversation) { create(:conversation, account: account, inbox: inbox) }
    let(:message) { create(:message, account: account, inbox: inbox, conversation: conversation, content: 'Привет!') }

    it 'adds a reaction and toggles it off when repeated by the same user' do
      described_class.new(message: message, user: user, emoji: '❤️').perform

      attrs = message.reload.content_attributes
      expect(attrs.dig('agent_reactions', "user:#{user.id}")).to include(
        'emoji' => '❤️',
        'user_id' => user.id,
        'user_name' => 'Арайлым'
      )

      # Toggling the same emoji removes it
      described_class.new(message: message, user: user, emoji: '❤️').perform
      expect(message.reload.content_attributes['agent_reactions']).to be_nil
    end

    it 'rejects invalid multi-character or non-emoji reactions' do
      expect do
        described_class.new(message: message, user: user, emoji: 'not-an-emoji').perform
      end.to raise_error(Messages::ReactionService::Error, 'Reaction must contain a single valid emoji')

      expect do
        described_class.new(message: message, user: user, emoji: '👍❤️').perform
      end.to raise_error(Messages::ReactionService::Error, 'Reaction must contain a single valid emoji')
    end

    it 'rejects reactions on activity or deleted messages' do
      activity_msg = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :activity, content: 'Joined')
      expect do
        described_class.new(message: activity_msg, user: user, emoji: '👍').perform
      end.to raise_error(Messages::ReactionService::Error, 'Cannot react to activity messages')

      deleted_msg = create(:message, account: account, inbox: inbox, conversation: conversation, content_attributes: { deleted: true })
      expect do
        described_class.new(message: deleted_msg, user: user, emoji: '👍').perform
      end.to raise_error(Messages::ReactionService::Error, 'Cannot react to deleted messages')
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

    it 'dispatches reaction to WhatsApp Cloud API and updates whatsapp_reactions' do
      stub = stub_request(:post, "https://graph.facebook.com/v25.0/#{channel.provider_config['phone_number_id']}/messages")
             .with do |req|
               body = JSON.parse(req.body)
               body['type'] == 'reaction' &&
                 body.dig('reaction', 'message_id') == 'wamid.target123' &&
                 body.dig('reaction', 'emoji') == '🔥'
             end
             .to_return(
               status: 200,
               body: { messages: [{ id: 'wamid.reaction1' }] }.to_json,
               headers: { 'Content-Type' => 'application/json' }
             )

      described_class.new(message: message, user: user, emoji: '🔥').perform

      expect(stub).to have_been_requested
      expect(message.reload.content_attributes.dig('whatsapp_reactions', 'business')).to include(
        'emoji' => '🔥',
        'user_id' => user.id,
        'user_name' => 'Арайлым'
      )
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
