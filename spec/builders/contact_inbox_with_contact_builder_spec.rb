require 'rails_helper'

describe ContactInboxWithContactBuilder do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, email: 'xyc@example.com', phone_number: '+23423424123', account: account, identifier: '123') }
  let(:existing_contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

  describe '#perform' do
    it 'doesnot create contact if it already exist with source id' do
      contact_inbox = described_class.new(
        source_id: existing_contact_inbox.source_id,
        inbox: inbox,
        contact_attributes: {
          name: 'Contact',
          phone_number: '+1234567890',
          email: 'testemail@example.com'
        }
      ).perform

      expect(contact_inbox.contact.id).to be(contact.id)
    end

    it 'creates contact if contact doesnot exist with source id' do
      contact_inbox = described_class.new(
        source_id: '123456',
        inbox: inbox,
        contact_attributes: {
          name: 'Contact',
          phone_number: '+1234567890',
          email: 'testemail@example.com',
          custom_attributes: { test: 'test' }
        }
      ).perform

      expect(contact_inbox.contact.id).not_to eq(contact.id)
      expect(contact_inbox.contact.name).to eq('Contact')
      expect(contact_inbox.contact.custom_attributes).to eq({ 'test' => 'test' })
      expect(contact_inbox.inbox_id).to eq(inbox.id)
      expect(contact_inbox.channel_profile.display_name).to eq('Contact')
      expect(contact_inbox.channel_profile.phone_number).to eq('+1234567890')
    end

    it 'updates the channel profile when the contact inbox already exists' do
      contact_inbox = described_class.new(
        source_id: existing_contact_inbox.source_id,
        inbox: inbox,
        contact_attributes: {
          name: 'Channel Name',
          avatar_url: 'https://chatwoot-assets.local/channel-avatar.png',
          additional_attributes: { username: 'channel_user' }
        }
      ).perform

      expect(contact_inbox).to eq(existing_contact_inbox)
      expect(contact_inbox.channel_profile.display_name).to eq('Channel Name')
      expect(contact_inbox.channel_profile.avatar_url).to eq('https://chatwoot-assets.local/channel-avatar.png')
      expect(contact_inbox.channel_profile.username).to eq('channel_user')
    end

    it 'doesnot create contact if it already exist with identifier' do
      contact_inbox = described_class.new(
        source_id: '123456',
        inbox: inbox,
        contact_attributes: {
          name: 'Contact',
          identifier: contact.identifier,
          phone_number: contact.phone_number,
          email: 'testemail@example.com'
        }
      ).perform

      expect(contact_inbox.contact.id).to be(contact.id)
    end

    it 'doesnot create contact if it already exist with email' do
      contact_inbox = described_class.new(
        source_id: '123456',
        inbox: inbox,
        contact_attributes: {
          name: 'Contact',
          phone_number: '+1234567890',
          email: contact.email
        }
      ).perform

      expect(contact_inbox.contact.id).to be(contact.id)
    end

    it 'doesnot create contact when an uppercase email is passed for an already existing contact email' do
      contact_inbox = described_class.new(
        source_id: '123456',
        inbox: inbox,
        contact_attributes: {
          name: 'Contact',
          phone_number: '+1234567890',
          email: contact.email.upcase
        }
      ).perform

      expect(contact_inbox.contact.id).to be(contact.id)
    end

    it 'doesnot create contact if it already exist with phone number' do
      contact_inbox = described_class.new(
        source_id: '123456',
        inbox: inbox,
        contact_attributes: {
          name: 'Contact',
          phone_number: contact.phone_number,
          email: 'testemail@example.com'
        }
      ).perform

      expect(contact_inbox.contact.id).to be(contact.id)
    end

    it 'doesnot create contact if normalized phone number matches an existing contact' do
      kz_contact = create(:contact, account: account, phone_number: '+77011234567')

      contact_inbox = described_class.new(
        source_id: '77011234567',
        inbox: inbox,
        contact_attributes: {
          name: 'Contact',
          phone_number: '+7 701 123 4567',
          email: 'testemail@example.com'
        }
      ).perform

      expect(contact_inbox.contact.id).to be(kz_contact.id)
    end

    it 'reuses contact if it exists with the same source_id in a Facebook inbox when creating for Instagram inbox' do
      instagram_source_id = '123456789'

      # Create a Facebook page inbox with a contact using the same source_id
      facebook_inbox = create(:inbox, channel_type: 'Channel::FacebookPage', account: account)
      facebook_contact = create(:contact, account: account)
      facebook_contact_inbox = create(:contact_inbox, contact: facebook_contact, inbox: facebook_inbox, source_id: instagram_source_id)

      # Create an Instagram inbox
      instagram_inbox = create(:inbox, channel_type: 'Channel::Instagram', account: account)

      # Try to create a contact inbox with same source_id for Instagram
      contact_inbox = described_class.new(
        source_id: instagram_source_id,
        inbox: instagram_inbox,
        contact_attributes: {
          name: 'Instagram User',
          email: 'instagram_user@example.com'
        }
      ).perform

      # Should reuse the existing contact from Facebook
      expect(contact_inbox.contact.id).to eq(facebook_contact.id)
      # Make sure the contact inbox is not the same as the Facebook contact inbox
      expect(contact_inbox.id).not_to eq(facebook_contact_inbox.id)
      expect(contact_inbox.inbox_id).to eq(instagram_inbox.id)
    end

    it 'reuses contact if it exists with the same source_id in another Telegram inbox for the account' do
      telegram_user_id = '8269484707'
      existing_channel = create(:channel_telegram, account: account, bot_token: '8269484707:existing')
      existing_inbox = existing_channel.inbox
      existing_contact = create(:contact, account: account, additional_attributes: { social_telegram_user_id: telegram_user_id })
      existing_contact_inbox = create(:contact_inbox, contact: existing_contact, inbox: existing_inbox, source_id: telegram_user_id)
      new_channel = create(:channel_telegram, account: account, bot_token: '8269484707:new')
      new_inbox = new_channel.inbox

      contact_inbox = described_class.new(
        source_id: telegram_user_id,
        inbox: new_inbox,
        contact_attributes: {
          name: 'Telegram User',
          additional_attributes: { social_telegram_user_id: telegram_user_id }
        }
      ).perform

      expect(contact_inbox.contact.id).to eq(existing_contact.id)
      expect(contact_inbox.id).not_to eq(existing_contact_inbox.id)
      expect(contact_inbox.inbox_id).to eq(new_inbox.id)
    end

    it 'does not auto-create a CRM deal before a conversation exists for a newly created contact' do
      account.enable_features!('crm_deals')
      pipeline = create(
        :crm_pipeline,
        account: account,
        auto_create_deal_on_channel_contact: true
      )
      create(:crm_stage, account: account, pipeline: pipeline, default: true)

      described_class.new(
        source_id: 'new-channel-contact',
        inbox: inbox,
        contact_attributes: {
          name: 'New Channel Contact',
          email: 'new-channel-contact@example.com'
        }
      ).perform

      expect(account.crm_deals.where(pipeline: pipeline)).not_to exist
    end

    it 'does not auto-create a CRM deal before a conversation exists' do
      account.enable_features!('crm_deals')
      pipeline = create(
        :crm_pipeline,
        account: account,
        auto_create_deal_on_channel_contact: true
      )
      create(:crm_stage, account: account, pipeline: pipeline, default: true)

      described_class.new(
        source_id: 'existing-channel-contact',
        inbox: inbox,
        contact_attributes: {
          name: 'Contact',
          email: contact.email
        }
      ).perform

      expect(account.crm_deals.joins(:deal_contacts).where(crm_deal_contacts: { contact_id: contact.id })).not_to exist
    end
  end
end
