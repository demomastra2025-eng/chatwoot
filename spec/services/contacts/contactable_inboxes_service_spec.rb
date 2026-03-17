require 'rails_helper'

describe Contacts::ContactableInboxesService do
  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  before do
    stub_request(:post, /graph.facebook.com/)
  end

  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account, email: 'contact@example.com', phone_number: '+2320000') }
  let!(:twilio_sms) { create(:channel_twilio_sms, account: account) }
  let!(:twilio_sms_inbox) { create(:inbox, channel: twilio_sms, account: account) }
  let!(:twilio_whatsapp) { create(:channel_twilio_sms, medium: :whatsapp, account: account) }
  let!(:twilio_whatsapp_inbox) { create(:inbox, channel: twilio_whatsapp, account: account) }
  let!(:email_channel) { create(:channel_email, account: account) }
  let!(:email_inbox) { create(:inbox, channel: email_channel, account: account) }
  let!(:api_channel) { create(:channel_api, account: account) }
  let!(:api_inbox) { create(:inbox, channel: api_channel, account: account) }
  let!(:whatsapp_web_channel) { create(:channel_whatsapp_web, account: account) }
  let!(:whatsapp_web_inbox) { whatsapp_web_channel.inbox }
  let!(:website_inbox) { create(:inbox, channel: create(:channel_widget, account: account), account: account) }
  let!(:sms_inbox) { create(:inbox, channel: create(:channel_sms, account: account), account: account) }

  describe '#get' do
    it 'returns the contactable inboxes for the contact' do
      contactable_inboxes = described_class.new(contact: contact).get

      expect(contactable_inboxes).to include({ source_id: contact.phone_number, inbox: twilio_sms_inbox })
      expect(contactable_inboxes).to include({ source_id: "whatsapp:#{contact.phone_number}", inbox: twilio_whatsapp_inbox })
      expect(contactable_inboxes).to include({ source_id: contact.email, inbox: email_inbox })
      expect(contactable_inboxes).to include({ source_id: contact.phone_number.delete('+'), inbox: whatsapp_web_inbox })
      expect(contactable_inboxes).to include({ source_id: contact.phone_number, inbox: sms_inbox })
    end

    it 'doest not return the non contactable inboxes for the contact' do
      facebook_channel = create(:channel_facebook_page, account: account)
      facebook_inbox = create(:inbox, channel: facebook_channel, account: account)
      twitter_channel = create(:channel_twitter_profile, account: account)
      twitter_inbox = create(:inbox, channel: twitter_channel, account: account)

      contactable_inboxes = described_class.new(contact: contact).get

      expect(contactable_inboxes.pluck(:inbox)).not_to include(website_inbox)
      expect(contactable_inboxes.pluck(:inbox)).not_to include(facebook_inbox)
      expect(contactable_inboxes.pluck(:inbox)).not_to include(twitter_inbox)
    end

    context 'when api inbox is available' do
      it 'returns existing source id if contact inbox exists' do
        contact_inbox = create(:contact_inbox, inbox: api_inbox, contact: contact)

        contactable_inboxes = described_class.new(contact: contact).get
        expect(contactable_inboxes).to include({ source_id: contact_inbox.source_id, inbox: api_inbox })
      end
    end

    context 'when website inbox is available' do
      it 'returns existing source id if contact inbox exists without any conversations' do
        contact_inbox = create(:contact_inbox, inbox: website_inbox, contact: contact)

        contactable_inboxes = described_class.new(contact: contact).get
        expect(contactable_inboxes).to include({ source_id: contact_inbox.source_id, inbox: website_inbox })
      end

      it 'does not return existing source id if contact inbox exists with conversations' do
        contact_inbox = create(:contact_inbox, inbox: website_inbox, contact: contact)
        create(:conversation, contact: contact, inbox: website_inbox, contact_inbox: contact_inbox)

        contactable_inboxes = described_class.new(contact: contact).get
        expect(contactable_inboxes.pluck(:inbox)).not_to include(website_inbox)
      end
    end

    context 'when whatsapp web inbox is available' do
      it 'returns existing source id if contact inbox exists' do
        contact_inbox = create(:contact_inbox, inbox: whatsapp_web_inbox, contact: contact, source_id: '15550001111')

        contactable_inboxes = described_class.new(contact: contact).get
        expect(contactable_inboxes).to include({ source_id: contact_inbox.source_id, inbox: whatsapp_web_inbox })
      end
    end
  end
end
