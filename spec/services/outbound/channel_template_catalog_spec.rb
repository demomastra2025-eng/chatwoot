require 'rails_helper'

RSpec.describe Outbound::ChannelTemplateCatalog do
  let(:account) { create(:account) }

  describe '#as_json' do
    it 'lists approved WhatsApp templates with required params and channel metadata' do
      inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox

      payload = described_class.for(inbox: inbox, name: 'ticket_status_updated', language: 'en')

      expect(payload[:supports_channel_templates]).to be(true)
      expect(payload[:requires_template_for_outside_window]).to be(true)
      expect(payload[:provider]).to eq(inbox.channel.provider)
      expect(payload[:templates].size).to eq(1)
      expect(payload[:templates].first).to include(
        transport: 'whatsapp_cloud',
        name: 'ticket_status_updated',
        language: 'en',
        status: 'approved',
        supported: true
      )
      expect(payload[:templates].first[:required_params]).to include(
        { component: 'body', name: 'name', example: 'John' },
        { component: 'body', name: 'ticket_id', example: '2332' }
      )
    end

    it 'filters out unsupported WhatsApp templates from policy lookup while still exposing support status' do
      inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
      inbox.channel.update!(
        message_templates: [
          {
            'name' => 'auth_code',
            'status' => 'approved',
            'category' => 'AUTHENTICATION',
            'language' => 'en',
            'components' => [{ 'type' => 'BODY', 'text' => 'Code {{1}}' }]
          }
        ]
      )

      catalog = described_class.new(inbox: inbox)
      payload = catalog.as_json

      expect(payload[:templates].first[:supported]).to be(false)
      expect(catalog.find_template(name: 'auth_code', language: 'en')).to be_nil
    end

    it 'lists approved Twilio WhatsApp templates' do
      channel = create(:channel_twilio_sms, medium: :whatsapp, account: account)
      inbox = create(:inbox, channel: channel, account: account)
      channel.update!(
        content_templates: {
          'templates' => [
            {
              'content_sid' => 'HX123',
              'friendly_name' => 'appointment_reminder',
              'language' => 'en',
              'status' => 'approved',
              'template_type' => 'twilio/text',
              'body' => 'Hi {{1}}, see you on {{2}}',
              'variables' => { '1' => 'John', '2' => 'Monday' }
            }
          ]
        },
        content_templates_last_updated: Time.current
      )

      payload = described_class.for(inbox: inbox)

      expect(payload[:provider]).to eq('twilio_whatsapp')
      expect(payload[:templates].first).to include(
        transport: 'twilio_whatsapp',
        content_sid: 'HX123',
        name: 'appointment_reminder',
        status: 'approved',
        supported: true
      )
      expect(payload[:templates].first[:required_params]).to include(
        { component: 'body', name: '1', example: 'John' },
        { component: 'body', name: '2', example: 'Monday' }
      )
    end

    it 'returns a templates-not-required payload for non-template channels' do
      inbox = create(:inbox, account: account)

      payload = described_class.for(inbox: inbox)

      expect(payload[:supports_channel_templates]).to be(false)
      expect(payload[:templates]).to eq([])
      expect(payload[:notes].first).to include('does not require channel templates')
    end
  end
end
