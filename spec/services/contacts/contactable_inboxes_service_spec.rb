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
  let!(:telegram_personal_channel) { create(:channel_telegram_personal, account: account) }
  let!(:telegram_personal_inbox) { telegram_personal_channel.inbox }
  let!(:telegram_channel) { create(:channel_telegram, account: account) }
  let!(:telegram_inbox) { telegram_channel.inbox }
  let!(:vk_community_channel) { create(:channel_vk_community, account: account) }
  let!(:vk_community_inbox) { vk_community_channel.inbox }
  let!(:line_channel) { create(:channel_line, account: account, inbox: nil) }
  let!(:line_inbox) { create(:inbox, channel: line_channel, account: account) }
  let!(:tiktok_channel) { create(:channel_tiktok, account: account) }
  let!(:tiktok_inbox) { tiktok_channel.inbox }
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

    it 'does not return the non contactable inboxes for the contact' do
      facebook_channel = create(:channel_facebook_page, account: account)
      facebook_inbox = create(:inbox, channel: facebook_channel, account: account)
      twitter_channel = create(:channel_twitter_profile, account: account)
      twitter_inbox = create(:inbox, channel: twitter_channel, account: account)

      contactable_inboxes = described_class.new(contact: contact).get

      expect(contactable_inboxes.pluck(:inbox)).not_to include(website_inbox)
      expect(contactable_inboxes.pluck(:inbox)).not_to include(facebook_inbox)
      expect(contactable_inboxes.pluck(:inbox)).not_to include(twitter_inbox)
      expect(contactable_inboxes.pluck(:inbox)).not_to include(tiktok_inbox)
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

    context 'when telegram personal inbox is available' do
      it 'returns the telegram user id from contact attributes' do
        contact.update!(additional_attributes: { 'social_telegram_user_id' => 4242 })

        contactable_inboxes = described_class.new(contact: contact).get
        expect(contactable_inboxes).to include({ source_id: '4242', inbox: telegram_personal_inbox })
      end
    end

    context 'when telegram bot inbox is available' do
      it 'returns the telegram user id from contact attributes' do
        contact.update!(additional_attributes: { 'social_telegram_user_id' => 7788 })

        contactable_inboxes = described_class.new(contact: contact).get
        expect(contactable_inboxes).to include({ source_id: '7788', inbox: telegram_inbox })
      end
    end

    context 'when vk community inbox is available' do
      it 'returns existing source id if contact inbox exists' do
        contact_inbox = create(:contact_inbox, inbox: vk_community_inbox, contact: contact, source_id: '2000000001')

        contactable_inboxes = described_class.new(contact: contact).get
        expect(contactable_inboxes).to include({ source_id: contact_inbox.source_id, inbox: vk_community_inbox })
      end
    end

    context 'when line inbox is available' do
      it 'returns existing source id if contact inbox exists' do
        contact_inbox = create(:contact_inbox, inbox: line_inbox, contact: contact, source_id: 'line-user-1')

        contactable_inboxes = described_class.new(contact: contact).get
        expect(contactable_inboxes).to include({ source_id: contact_inbox.source_id, inbox: line_inbox })
      end
    end

    context 'when facebook inbox is available' do
      it 'returns existing source id if contact inbox exists' do
        channel = create(:channel_facebook_page, account: account, inbox: nil)
        inbox = create(:inbox, channel: channel, account: account)
        contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'fb-user-1')

        contactable_inboxes = described_class.new(contact: contact).get
        expect(contactable_inboxes).to include({ source_id: contact_inbox.source_id, inbox: inbox })
      end
    end

    context 'when instagram inbox is available' do
      it 'returns existing source id if contact inbox exists' do
        channel = create(:channel_instagram, account: account)
        inbox = channel.inbox
        contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'ig-user-1')

        contactable_inboxes = described_class.new(contact: contact).get
        expect(contactable_inboxes).to include({ source_id: contact_inbox.source_id, inbox: inbox })
      end
    end

    context 'when tiktok inbox is available' do
      it 'returns existing source id if contact inbox exists' do
        contact_inbox = create(:contact_inbox, inbox: tiktok_inbox, contact: contact, source_id: 'tt-conv-1')

        contactable_inboxes = described_class.new(contact: contact).get
        expect(contactable_inboxes).to include({ source_id: contact_inbox.source_id, inbox: tiktok_inbox })
      end
    end

    context 'when linkedin personal inbox is available' do
      it 'returns existing source id if contact inbox exists' do
        inbox = create(:channel_linkedin_personal, account: account).inbox
        contact_inbox = create(
          :contact_inbox,
          inbox: inbox,
          contact: contact,
          source_id: 'urn:li:fsd_profile:lead-1'
        )

        contactable_inboxes = described_class.new(contact: contact).get
        expect(contactable_inboxes).to include(
          { source_id: contact_inbox.source_id, inbox: inbox }
        )
      end
    end

    context 'when weixin inbox is available' do
      it 'returns existing source id if contact inbox exists' do
        inbox = create(:channel_weixin, account: account).inbox
        contact_inbox = create(
          :contact_inbox,
          inbox: inbox,
          contact: contact,
          source_id: 'wx-user-1'
        )

        contactable_inboxes = described_class.new(contact: contact).get
        expect(contactable_inboxes).to include(
          { source_id: contact_inbox.source_id, inbox: inbox }
        )
      end
    end

    context 'when twitter inbox has an existing direct-message thread' do
      it 'returns the twitter user target for outbound direct messages' do
        channel = create(:channel_twitter_profile, account: account)
        inbox = create(:inbox, channel: channel, account: account)
        contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'tw-user-1')
        create(
          :conversation,
          inbox: inbox,
          account: account,
          contact: contact,
          contact_inbox: contact_inbox,
          additional_attributes: { type: 'direct_message' }
        )

        contactable_inboxes = described_class.new(contact: contact).get
        expect(contactable_inboxes).to include({ source_id: contact_inbox.source_id, inbox: inbox })
      end
    end
  end
end
