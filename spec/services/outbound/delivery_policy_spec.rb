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

    it 'uses a preloaded incoming timestamp without an existing conversation' do
      whatsapp_inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox

      result = described_class.evaluate(
        inbox: whatsapp_inbox,
        content_kind: 'free_text',
        last_incoming_message_at: 1.hour.ago
      )

      expect(result).to be_allowed
      expect(result.reply_window_open).to be(true)
    end

    context 'when the customer has more than one conversation or number in the inbox' do
      let(:whatsapp_inbox) { create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox }
      let(:customer_number) { create(:contact_inbox, contact: contact, inbox: whatsapp_inbox) }
      let(:other_number) { create(:contact_inbox, contact: contact, inbox: whatsapp_inbox) }

      def conversation_on(contact_inbox)
        create(:conversation, account: account, inbox: whatsapp_inbox, contact: contact, contact_inbox: contact_inbox)
      end

      def customer_wrote(conversation, at)
        create(:message, account: account, inbox: whatsapp_inbox, conversation: conversation, message_type: 'incoming', created_at: at)
      end

      it 'uses the incoming messages the customer wrote from the same number in any conversation of the inbox' do
        previous_conversation = conversation_on(customer_number)
        new_conversation = conversation_on(customer_number)
        customer_wrote(previous_conversation, 1.hour.ago)

        result = described_class.evaluate(conversation: new_conversation, content_kind: 'free_text')

        expect(result).to be_allowed
        expect(result.reply_window_open).to be(true)
      end

      it 'counts the user id the customer wrote with and the phone number the staff writes to as one customer' do
        by_user_id = create(:contact_inbox, contact: contact, inbox: whatsapp_inbox, source_id: 'AB.providerbsuid123')
        customer_wrote(conversation_on(by_user_id), 1.hour.ago)

        result = described_class.evaluate(conversation: conversation_on(customer_number), content_kind: 'free_text')

        expect(result).to be_allowed
        expect(result.reply_window_open).to be(true)
      end

      it 'does not use the messages the same person wrote from another phone number: each number has its own window' do
        customer_wrote(conversation_on(customer_number), 1.hour.ago)

        result = described_class.evaluate(conversation: conversation_on(other_number), content_kind: 'free_text')

        expect(result).not_to be_allowed
        expect(result.requires_template).to be(true)
        expect(result.reply_window_open).to be(false)
      end

      it 'looks at the customer a message to another inbox of the person goes to' do
        customer_wrote(conversation_on(customer_number), 1.hour.ago)
        other_inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
        in_other_inbox = create(:contact_inbox, contact: contact, inbox: other_inbox)
        customer_wrote(create(:conversation, account: account, inbox: other_inbox, contact: contact, contact_inbox: in_other_inbox), 30.hours.ago)

        result = described_class.evaluate(conversation: conversation_on(customer_number), inbox: other_inbox, content_kind: 'free_text')

        expect(result).not_to be_allowed
        expect(result.reply_window_open).to be(false)
      end
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

    context 'with Twilio WhatsApp, which has the same 24-hour customer service window as the official WhatsApp' do
      let(:twilio_inbox) { create(:inbox, channel: create(:channel_twilio_sms, medium: :whatsapp, account: account), account: account) }

      it 'allows free text while the customer wrote within the window' do
        conversation = conversation_for(twilio_inbox)
        create(:message, account: account, inbox: twilio_inbox, conversation: conversation, message_type: 'incoming', created_at: 1.hour.ago)

        result = described_class.evaluate(conversation: conversation, content_kind: 'free_text')

        expect(result).to be_allowed
        expect(result.provider).to eq('twilio_whatsapp')
        expect(result.reply_window_open).to be(true)
      end

      it 'asks for a content template when the customer never wrote, or wrote longer ago', :aggregate_failures do
        conversation = conversation_for(twilio_inbox)

        result = described_class.evaluate(conversation: conversation, content_kind: 'free_text')

        expect(result).not_to be_allowed
        expect(result.provider).to eq('twilio_whatsapp')
        expect(result.requires_template).to be(true)
        expect(result.reason).to eq(described_class::TWILIO_WHATSAPP_TEMPLATE_REQUIRED_REASON)
        expect(result.allowed_content_kinds).to eq(['channel_template'])
      end

      it 'asks for a content template when the window will be closed at delivery time' do
        conversation = conversation_for(twilio_inbox)
        create(:message, account: account, inbox: twilio_inbox, conversation: conversation, message_type: 'incoming', created_at: 1.hour.ago)

        result = described_class.evaluate(conversation: conversation, content_kind: 'free_text', scheduled_at: 3.days.from_now)

        expect(result).not_to be_allowed
        expect(result.requires_template).to be(true)
      end
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
