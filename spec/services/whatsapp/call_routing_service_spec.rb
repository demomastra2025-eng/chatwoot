require 'rails_helper'

RSpec.describe Whatsapp::CallRoutingService do
  subject(:decision) { described_class.new(call: call).perform }

  let(:account) { create(:account) }
  let(:channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      provider_config: {
        'source' => 'embedded_signup',
        'calling_enabled' => true,
        'media_server_enabled' => true,
        'ai_voice_enabled' => true
      },
      validate_provider_config: false,
      sync_templates: false
    )
  end
  let(:inbox) { channel.inbox }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, :with_phone_number, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, status: conversation_status) }
  let(:call) do
    create(
      :call,
      account: account,
      inbox: inbox,
      contact: contact,
      conversation: conversation,
      provider: :whatsapp,
      direction: :incoming,
      status: 'ringing'
    )
  end

  before do
    Current.suppress_runtime_events = true
    Conversation.skip_callback(:create, :before, :determine_conversation_status)
    Conversation.skip_callback(:commit, :after, :notify_conversation_creation)
    account.enable_features!('whatsapp_call')
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
  end

  after do
    Conversation.set_callback(:commit, :after, :notify_conversation_creation, on: :create)
    Conversation.set_callback(:create, :before, :determine_conversation_status)
    Current.suppress_runtime_events = nil
  end

  context 'when conversation is open' do
    let(:conversation_status) { 'open' }

    it 'routes the call to the human operator UI and never auto-answers by AI' do
      expect(decision).to have_attributes(
        action: 'human_ring',
        reason: 'conversation_open_operator_owns_call',
        conversation_status: 'open',
        assistant: assistant
      )
      expect(decision.ai?).to be(false)
      expect(decision.human?).to be(true)
    end
  end

  context 'when conversation is pending' do
    let(:conversation_status) { 'pending' }

    it 'routes the call to the AI voice agent when Captain AI voice is enabled' do
      expect(decision).to have_attributes(
        action: 'ai_accept',
        reason: 'conversation_pending_ai_voice_enabled',
        conversation_status: 'pending',
        assistant: assistant
      )
      expect(decision.ai?).to be(true)
      expect(decision.human?).to be(false)
    end
  end

  context 'when conversation is pending but AI voice is disabled on the WhatsApp inbox' do
    let(:conversation_status) { 'pending' }

    before do
      channel.update!(provider_config: channel.provider_config.merge('ai_voice_enabled' => false))
    end

    it 'fails safe to the human operator UI' do
      expect(decision).to have_attributes(
        action: 'human_ring',
        reason: 'conversation_pending_ai_voice_disabled',
        conversation_status: 'pending',
        assistant: assistant
      )
      expect(decision.ai?).to be(false)
      expect(decision.human?).to be(true)
    end
  end
end
