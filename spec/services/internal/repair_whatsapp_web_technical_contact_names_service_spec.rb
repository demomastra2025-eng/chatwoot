require 'rails_helper'

RSpec.describe Internal::RepairWhatsappWebTechnicalContactNamesService do
  describe '#perform' do
    let(:channel) { create(:channel_whatsapp_web) }

    it 'replaces a lid-based technical name with the phone number' do
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

      repaired = described_class.new(account: channel.account).perform

      expect(repaired).to eq(1)
      expect(contact.reload.name).to eq('+77077064008')
    end

    it 'replaces a digits-only technical name with the phone number' do
      contact = create(
        :contact,
        account: channel.account,
        name: '77011332311',
        phone_number: '+77011332311',
        additional_attributes: { 'provider' => 'whatsapp_web' }
      )
      create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '77011332311')

      repaired = described_class.new(account: channel.account).perform

      expect(repaired).to eq(1)
      expect(contact.reload.name).to eq('+77011332311')
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
  end
end
