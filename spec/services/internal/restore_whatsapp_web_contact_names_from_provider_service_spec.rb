require 'rails_helper'

RSpec.describe Internal::RestoreWhatsappWebContactNamesFromProviderService do
  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  describe '#perform' do
    it 'replays provider contact records through whatsapp web contact sync' do
      channel = create(:channel_whatsapp_web)
      contact = create(
        :contact,
        account: channel.account,
        name: '+77077489629',
        phone_number: '+77077489629',
        identifier: 'whatsapp_web:129115340464278@lid',
        additional_attributes: {
          'raw_jid' => '77077489629@s.whatsapp.net',
          'canonical_jid' => '77077489629@s.whatsapp.net',
          'lid_jid' => '129115340464278@lid',
          'provider' => 'whatsapp_web'
        }
      )
      contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '77077489629')
      provider_service = instance_double(WhatsappWeb::Providers::EvolutionService)
      sync_service = instance_double(WhatsappWeb::ContactSyncService, perform: contact_inbox)

      allow_any_instance_of(Channel::WhatsappWeb).to receive(:provider_service).and_return(provider_service)
      allow(provider_service).to receive(:fetch_contacts).with(page: 1, offset: 100).and_return(
        [
          {
            remoteJid: '77077489629@s.whatsapp.net',
            pushName: 'Максим',
            profilePicUrl: 'https://example.com/avatar.png'
          }
        ]
      )
      allow(WhatsappWeb::ContactSyncService).to receive(:new).and_return(sync_service)

      result = described_class.new(account: channel.account).perform

      expect(result).to include(channels_processed: 1, contacts_touched: 1, errors: [])
      expect(WhatsappWeb::ContactSyncService).to have_received(:new).with(
        channel: an_instance_of(Channel::WhatsappWeb),
        contact_payload: hash_including(
          remoteJid: '77077489629@s.whatsapp.net',
          pushName: 'Максим',
          profilePicUrl: 'https://example.com/avatar.png'
        )
      )
      expect(sync_service).to have_received(:perform)
    end
  end
end
