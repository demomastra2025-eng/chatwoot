require 'rails_helper'

RSpec.describe Internal::RepairWhatsappWebTechnicalContactNamesService do
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
    let(:channel) { create(:channel_whatsapp_web) }

    it 'repairs a technical lid-based name when a better local whatsapp profile name exists' do
      contact = create(
        :contact,
        account: channel.account,
        name: '249262822686958@lid',
        phone_number: '+77077064008',
        identifier: 'whatsapp_web:249262822686958@lid',
        additional_attributes: {
          'raw_jid' => '249262822686958@lid',
          'canonical_jid' => '77077064008@s.whatsapp.net',
          'lid_jid' => '249262822686958@lid',
          'provider' => 'whatsapp_web'
        }
      )
      create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '249262822686958@lid')
      profile = create(
        :contact_channel_profile,
        contact: contact,
        contact_inbox: contact.contact_inboxes.first,
        inbox: channel.inbox,
        provider: 'whatsapp_web',
        source_id: '249262822686958@lid',
        display_name: 'Maxim',
        phone_number: '+77077064008',
        profile_data: {
          'identifier' => 'whatsapp_web:249262822686958@lid',
          'lid_jid' => '249262822686958@lid',
          'raw_jid' => '249262822686958@lid',
          'canonical_jid' => '249262822686958@lid',
          'display_name' => 'Maxim',
          'name' => 'Maxim',
          'phone_number' => '+77077064008'
        }
      )

      repaired = described_class.new(account: channel.account).perform

      expect(repaired).to eq(1)
      expect(contact.reload.name).to eq('Maxim')
      expect(profile.reload.display_name).to eq('Maxim')
      expect(profile.profile_data).to include(
        'display_name' => 'Maxim',
        'name' => 'Maxim',
        'phone_number' => '+77077064008'
      )
    end

    it 'does not fall back to the phone number when no trusted local human-readable name exists' do
      contact = create(
        :contact,
        account: channel.account,
        name: '77011332311',
        phone_number: '+77011332311',
        additional_attributes: { 'provider' => 'whatsapp_web' }
      )
      create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '77011332311')

      repaired = described_class.new(account: channel.account).perform

      expect(repaired).to eq(0)
      expect(contact.reload.name).to eq('77011332311')
    end

    it 'does not overwrite a human-readable name' do
      contact = create(
        :contact,
        account: channel.account,
        name: 'Alice',
        phone_number: '+77077064008',
        identifier: 'whatsapp_web:249262822686958@lid',
        additional_attributes: {
          'raw_jid' => '249262822686958@lid',
          'canonical_jid' => '77077064008@s.whatsapp.net',
          'lid_jid' => '249262822686958@lid',
          'provider' => 'whatsapp_web'
        }
      )
      create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '249262822686958@lid')

      repaired = described_class.new(account: channel.account).perform

      expect(repaired).to eq(0)
      expect(contact.reload.name).to eq('Alice')
    end

    it 'repairs a stale whatsapp channel profile even when the unicode human-readable name only survives in profile_data' do
      contact = create(
        :contact,
        account: channel.account,
        name: '249262822686958@lid',
        phone_number: '+77077064008',
        identifier: 'whatsapp_web:249262822686958@lid',
        additional_attributes: {
          'raw_jid' => '249262822686958@lid',
          'canonical_jid' => '77077064008@s.whatsapp.net',
          'lid_jid' => '249262822686958@lid',
          'provider' => 'whatsapp_web'
        }
      )
      contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '249262822686958@lid')
      profile = create(
        :contact_channel_profile,
        contact: contact,
        contact_inbox: contact_inbox,
        inbox: channel.inbox,
        provider: 'whatsapp_web',
        source_id: '249262822686958@lid',
        display_name: '249262822686958@lid',
        phone_number: '+77077064008',
        profile_data: {
          'identifier' => 'whatsapp_web:249262822686958@lid',
          'lid_jid' => '249262822686958@lid',
          'raw_jid' => '249262822686958@lid',
          'canonical_jid' => '249262822686958@lid',
          'display_name' => '249262822686958@lid',
          'name' => 'Максим',
          'phone_number' => '+77077064008'
        }
      )

      repaired = described_class.new(account: channel.account).perform

      expect(repaired).to eq(1)
      expect(contact.reload.name).to eq('Максим')
      expect(profile.reload.display_name).to eq('Максим')
    end

    it 'repairs a technical name from the stored last provider display name' do
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
      profile = create(
        :contact_channel_profile,
        contact: contact,
        contact_inbox: contact_inbox,
        inbox: channel.inbox,
        provider: 'whatsapp_web',
        source_id: '77077489629',
        display_name: '+77077489629',
        phone_number: '+77077489629',
        profile_data: {
          'identifier' => 'whatsapp_web:129115340464278@lid',
          'raw_jid' => '77077489629@s.whatsapp.net',
          'canonical_jid' => '77077489629@s.whatsapp.net',
          'lid_jid' => '129115340464278@lid',
          'display_name' => '+77077489629',
          'name' => '+77077489629',
          'last_provider_display_name' => 'Максим',
          'phone_number' => '+77077489629'
        }
      )

      repaired = described_class.new(account: channel.account).perform

      expect(repaired).to eq(1)
      expect(contact.reload.name).to eq('Максим')
      expect(profile.reload.display_name).to eq('Максим')
    end

    it 'prefers a better whatsapp profile name over the phone number when repairing reception placeholders' do
      contact = create(
        :contact,
        account: channel.account,
        name: 'RECEPTION',
        phone_number: '+77072271414',
        identifier: 'whatsapp_web:134961562669211@lid',
        additional_attributes: {
          'raw_jid' => '77072271414@s.whatsapp.net',
          'canonical_jid' => '77072271414@s.whatsapp.net',
          'lid_jid' => '134961562669211@lid',
          'provider' => 'whatsapp_web'
        }
      )
      contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '77072271414')
      lid_contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '134961562669211@lid')
      primary_profile = create(
        :contact_channel_profile,
        contact: contact,
        contact_inbox: contact_inbox,
        inbox: channel.inbox,
        provider: 'whatsapp_web',
        source_id: '77072271414',
        display_name: 'VSETUT KAZAKHSTAN',
        phone_number: '+77072271414',
        profile_data: {
          'identifier' => 'whatsapp_web:134961562669211@lid',
          'lid_jid' => '134961562669211@lid',
          'raw_jid' => '77072271414@s.whatsapp.net',
          'canonical_jid' => '77072271414@s.whatsapp.net',
          'display_name' => 'VSETUT KAZAKHSTAN',
          'name' => 'VSETUT KAZAKHSTAN',
          'phone_number' => '+77072271414'
        }
      )
      lid_profile = create(
        :contact_channel_profile,
        contact: contact,
        contact_inbox: lid_contact_inbox,
        inbox: channel.inbox,
        provider: 'whatsapp_web',
        source_id: '134961562669211@lid',
        display_name: '134961562669211@lid',
        phone_number: nil,
        profile_data: {
          'identifier' => 'whatsapp_web:134961562669211@lid',
          'lid_jid' => '134961562669211@lid',
          'raw_jid' => '134961562669211@lid',
          'canonical_jid' => '134961562669211@lid',
          'display_name' => '134961562669211@lid',
          'name' => '134961562669211@lid'
        }
      )

      repaired = described_class.new(account: channel.account).perform

      expect(repaired).to eq(1)
      expect(contact.reload.name).to eq('VSETUT KAZAKHSTAN')
      expect(primary_profile.reload.display_name).to eq('VSETUT KAZAKHSTAN')
      expect(lid_profile.reload.display_name).to eq('VSETUT KAZAKHSTAN')
      expect(lid_profile.phone_number).to eq('+77072271414')
      expect(lid_profile.profile_data).to include(
        'display_name' => 'VSETUT KAZAKHSTAN',
        'name' => 'VSETUT KAZAKHSTAN',
        'phone_number' => '+77072271414'
      )
    end
  end
end
