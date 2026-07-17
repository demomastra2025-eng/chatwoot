require 'rails_helper'

RSpec.describe Outbound::DeliveryPolicy do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }

  def conversation_for(inbox)
    create(:conversation, account: account, inbox: inbox, contact: contact)
  end

  describe '.evaluate' do
    it 'allows free text for ordinary channels without requiring templates' do
      inbox = create(:inbox, account: account)
      conversation = conversation_for(inbox)

      result = described_class.evaluate(conversation: conversation, content_kind: 'free_text')

      expect(result).to be_allowed
      expect(result.delivery_mode).to eq('free_text')
      expect(result.requires_template).to be(false)
      expect(result.allowed_content_kinds).to eq(['free_text'])
    end

    it 'treats template_params as metadata on ordinary channels unless channel templates are supported' do
      inbox = create(:inbox, account: account)
      conversation = conversation_for(inbox)

      result = described_class.evaluate(
        conversation: conversation,
        template_params: { name: 'campaign_metadata' }
      )

      expect(result).to be_allowed
      expect(result.delivery_mode).to eq('free_text')
      expect(result.content_kind).to eq('free_text')
    end

    it 'allows WhatsApp Business free text while the 24-hour reply window is open' do
      whatsapp_inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
      conversation = conversation_for(whatsapp_inbox)
      create(:message, account: account, inbox: whatsapp_inbox, conversation: conversation, message_type: 'incoming', created_at: 1.hour.ago)

      result = described_class.evaluate(conversation: conversation, content_kind: 'free_text')

      expect(result).to be_allowed
      expect(result.reply_window_open).to be(true)
      expect(result.allowed_content_kinds).to contain_exactly('free_text', 'channel_template')
    end

    it 'uses a preloaded incoming timestamp for WhatsApp reply-window checks' do
      whatsapp_inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
      conversation = conversation_for(whatsapp_inbox)
      expect(conversation).not_to receive(:messages)

      result = described_class.evaluate(
        conversation: conversation,
        content_kind: 'free_text',
        last_incoming_message_at: 1.hour.ago
      )

      expect(result).to be_allowed
      expect(result.reply_window_open).to be(true)
    end

    it 'denies WhatsApp Business free text when the 24-hour reply window is closed' do
      whatsapp_inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
      conversation = conversation_for(whatsapp_inbox)
      create(:message, account: account, inbox: whatsapp_inbox, conversation: conversation, message_type: 'incoming', created_at: 25.hours.ago)

      result = described_class.evaluate(conversation: conversation, content_kind: 'free_text')

      expect(result).not_to be_allowed
      expect(result.requires_template).to be(true)
      expect(result.reason).to include('approved channel_template')
      expect(result.allowed_content_kinds).to eq(['channel_template'])
    end

    it 'denies scheduled WhatsApp Business free text when the window will be closed at delivery time' do
      whatsapp_inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
      conversation = conversation_for(whatsapp_inbox)
      create(:message, account: account, inbox: whatsapp_inbox, conversation: conversation, message_type: 'incoming', created_at: 1.hour.ago)

      result = described_class.evaluate(conversation: conversation, content_kind: 'free_text', scheduled_at: 25.hours.from_now)

      expect(result).not_to be_allowed
      expect(result.requires_template).to be(true)
    end

    it 'allows approved WhatsApp Business channel templates outside the reply window' do
      whatsapp_inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
      conversation = conversation_for(whatsapp_inbox)

      result = described_class.evaluate(
        conversation: conversation,
        content_kind: 'channel_template',
        template_params: {
          name: 'sample_shipping_confirmation',
          language: 'en_US',
          namespace: '23423423_2342423_324234234_2343224',
          processed_params: { '1' => '2' }
        }
      )

      expect(result).to be_allowed
      expect(result.delivery_mode).to eq('channel_template')
      expect(result.template[:name]).to eq('sample_shipping_confirmation')
    end

    it 'infers WhatsApp channel_template mode from JSON string template params' do
      whatsapp_inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
      conversation = conversation_for(whatsapp_inbox)

      result = described_class.evaluate(
        conversation: conversation,
        template_params: {
          name: 'sample_shipping_confirmation',
          language: 'en_US',
          namespace: '23423423_2342423_324234234_2343224'
        }.to_json
      )

      expect(result).to be_allowed
      expect(result.delivery_mode).to eq('channel_template')
      expect(result.content_kind).to eq('channel_template')
    end

    it 'does not apply WhatsApp Business template rules to WhatsApp Web' do
      with_modified_env(
        'EVOLUTION_API_URL' => 'https://evolution.example.com',
        'EVOLUTION_API_KEY' => 'test-api-key',
        'FRONTEND_URL' => 'https://app.example.com'
      ) do
        whatsapp_web_inbox = create(:channel_whatsapp_web, account: account).inbox
        conversation = conversation_for(whatsapp_web_inbox)

        result = described_class.evaluate(conversation: conversation, content_kind: 'free_text', scheduled_at: 3.days.from_now)

        expect(result).to be_allowed
        expect(result.requires_template).to be(false)
        expect(result.allowed_content_kinds).to eq(['free_text'])
      end
    end

    it 'does not apply official WhatsApp 24-hour template rules to Twilio WhatsApp' do
      twilio_channel = create(:channel_twilio_sms, medium: :whatsapp, account: account)
      twilio_inbox = create(:inbox, channel: twilio_channel, account: account)
      conversation = conversation_for(twilio_inbox)

      result = described_class.evaluate(conversation: conversation, content_kind: 'free_text', scheduled_at: 3.days.from_now)

      expect(result).to be_allowed
      expect(result.provider).to eq('twilio_whatsapp')
      expect(result.requires_template).to be(false)
    end

    it 'allows Twilio WhatsApp content templates by content_sid' do
      twilio_channel = create(:channel_twilio_sms, medium: :whatsapp, account: account)
      twilio_channel.update!(
        content_templates: {
          'templates' => [
            {
              'content_sid' => 'HX123',
              'friendly_name' => 'appointment_reminder',
              'language' => 'en',
              'status' => 'approved',
              'body' => 'Hi {{1}}',
              'variables' => { '1' => 'John' }
            }
          ]
        }
      )
      twilio_inbox = create(:inbox, channel: twilio_channel, account: account)
      conversation = conversation_for(twilio_inbox)

      result = described_class.evaluate(
        conversation: conversation,
        content_kind: 'channel_template',
        template_params: { content_sid: 'HX123', language: 'en', content_variables: { '1' => 'John' } }
      )

      expect(result).to be_allowed
      expect(result.delivery_mode).to eq('channel_template')
      expect(result.template[:content_sid]).to eq('HX123')
    end

    it 'denies delivery for channels without an outbound send service' do
      allow_any_instance_of(Channel::Voice).to receive(:provision_twilio_on_create)
      voice_inbox = create(:channel_voice, account: account).inbox
      conversation = conversation_for(voice_inbox)

      result = described_class.evaluate(conversation: conversation, content_kind: 'free_text')

      expect(result).not_to be_allowed
      expect(result.reason).to eq(Outbound::DeliveryPolicy::OUTBOUND_CHANNEL_UNSUPPORTED_REASON)
    end

    it 'allows delivery for channels with an outbound send service' do
      telegram_inbox = create(:channel_telegram, account: account).inbox
      conversation = conversation_for(telegram_inbox)

      result = described_class.evaluate(conversation: conversation, content_kind: 'free_text')

      expect(result).to be_allowed
    end
  end
end
