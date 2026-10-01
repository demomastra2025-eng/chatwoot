require 'rails_helper'

RSpec.describe Contacts::SharedPhone do
  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-api-key',
                      'FRONTEND_URL' => 'https://app.example.com') { example.run }
  end

  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }
  let(:phone) { '+77000000009' }
  let(:digits) { '77000000009' }

  def share_attributes(owner_id:, via: described_class::VIA_BOOKING_CHAT, secondary: [phone])
    { described_class::SHARED_PHONE_KEY => phone, described_class::SHARED_OWNER_KEY => owner_id,
      described_class::SHARED_VIA_KEY => via, 'secondary_phones' => secondary, described_class::CARD_KEY => true }
  end

  def whatsapp_inbox
    stub_request(:post, 'https://waba.360dialog.io/v1/configs/webhook')
    create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
  end

  describe '.share_of' do
    it 'is effective only while the number is still one of the доп. номера', :aggregate_failures do
      owner = create(:contact, account: account)
      card = create(:contact, account: account, custom_attributes: share_attributes(owner_id: owner.id))

      expect(described_class.share_of(card)).to have_attributes(phone: phone, owner_id: owner.id, via: 'booking_chat')
      card.update!(custom_attributes: card.custom_attributes.merge('secondary_phones' => []))
      expect(described_class.share_of(card)).to be_nil
    end

    it 'reads a v7 share (owner and number only) as the owner primary share' do
      owner = create(:contact, account: account, phone_number: phone)
      card = create(:contact, account: account, custom_attributes: { described_class::SHARED_OWNER_KEY => owner.id, 'secondary_phones' => [phone] })

      expect(described_class.share_of(card)).to have_attributes(phone: phone, owner_id: owner.id, via: 'owner_primary')
    end
  end

  describe '.identifying_contact_inboxes' do
    let(:owner) { create(:contact, account: account) }

    it 'finds phone-source chats of the number and ignores other channels', :aggregate_failures do
      cloud = create(:contact_inbox, contact: owner, inbox: whatsapp_inbox, source_id: digits)
      web_inbox = create(:channel_whatsapp_web, account: account).inbox
      web = create(:contact_inbox, contact: owner, inbox: web_inbox, source_id: digits)
      create(:contact_inbox, contact: owner, inbox: create(:inbox, account: account), source_id: digits)

      expect(described_class.identifying_contact_inboxes(account_id: account.id, phone: phone).pluck(:id)).to contain_exactly(cloud.id, web.id)
      expect(described_class.identity_owner_ids(account_id: account.id, phone: phone)).to eq([owner.id])
      expect(described_class.identity_owner_ids(account_id: account.id, phone: phone, excluding: [owner.id])).to be_empty
    end

    it 'P3 never counts a client-chosen API source id, and counts a voice caller id', :aggregate_failures do
      create(:contact_inbox, contact: owner, inbox: create(:channel_api, account: account).inbox, source_id: digits)
      expect(described_class.identifying_contact_inboxes(account_id: account.id, phone: phone)).to be_empty

      voice = create(:channel_voice, :sipuni, account: account, phone_number: '+77000000001')
      caller = create(:contact_inbox, contact: owner, inbox: voice.inbox, source_id: phone)
      expect(described_class.identifying_contact_inboxes(account_id: account.id, phone: phone).pluck(:id)).to eq([caller.id])
    end

    it 'ties a WhatsApp Web LID only when a resolved payload proved it, never through the copied profile phone', :aggregate_failures do
      web_inbox = create(:channel_whatsapp_web, account: account).inbox
      phone_ci = create(:contact_inbox, contact: owner, inbox: web_inbox, source_id: digits)
      lid_ci = create(:contact_inbox, contact: owner, inbox: web_inbox, source_id: '55555@lid')
      create(:contact_channel_profile, contact: owner, contact_inbox: lid_ci, phone_number: phone, profile_data: { 'phone_number' => phone })

      expect(described_class.identifying_contact_inboxes(account_id: account.id, phone: phone).pluck(:id)).to eq([phone_ci.id])

      create(:contact_channel_profile, contact: owner, contact_inbox: phone_ci, profile_data: { 'lid_jid' => '55555@lid' })
      expect(described_class.identifying_contact_inboxes(account_id: account.id, phone: phone).pluck(:id)).to contain_exactly(phone_ci.id, lid_ci.id)
    end

    it 'ties a Telegram peer only through its own payload phone and never through the channel own number', :aggregate_failures do
      channel = create(:channel_telegram_personal, account: account, phone_number: '+77000000555')
      peer = create(:contact_inbox, contact: owner, inbox: channel.inbox, source_id: '777001')
      create(:contact_channel_profile, contact: owner, contact_inbox: peer, phone_number: phone, profile_data: {})
      expect(described_class.identifying_contact_inboxes(account_id: account.id, phone: phone)).to be_empty

      # a phone copied from the contact into the profile (baseline, backfill) is not proof
      peer.channel_profile.update!(profile_data: { 'phone_number' => phone })
      expect(described_class.identifying_contact_inboxes(account_id: account.id, phone: phone)).to be_empty

      peer.channel_profile.update!(profile_data: { 'phone_number' => phone, 'peer_phone_number' => phone })
      expect(described_class.identifying_contact_inboxes(account_id: account.id, phone: phone).pluck(:id)).to eq([peer.id])

      self_peer = create(:contact_inbox, contact: owner, inbox: channel.inbox, source_id: '777002')
      create(:contact_channel_profile, contact: owner, contact_inbox: self_peer, profile_data: { 'peer_phone_number' => '+77000000555' })
      expect(described_class.identifying_contact_inboxes(account_id: account.id, phone: '+77000000555')).to be_empty
    end

    it 'T1 never ties a Telegram chat whose baseline profile copied the contact phone (bot or Personal)', :aggregate_failures do
      holder = create(:contact, account: account, name: 'Mother', phone_number: phone)
      bot_ci = ContactInboxBuilder.new(contact: holder, inbox: create(:channel_telegram, account: account).inbox, source_id: '424242').perform
      personal = create(:channel_telegram_personal, account: account, phone_number: '+77000000555')
      personal_ci = ContactInboxBuilder.new(contact: holder, inbox: personal.inbox, source_id: '55501').perform
      Contacts::ChannelProfileBackfillService.new(scope: ContactInbox.where(id: [bot_ci.id, personal_ci.id]), force: true).perform

      expect(ContactChannelProfile.find_by(contact_inbox_id: personal_ci.id).profile_data['phone_number']).to eq(phone)
      expect(described_class.identifying_contact_inboxes(account_id: account.id, phone: phone)).to be_empty
    end
  end

  describe '.assignable_primary?' do
    let(:contact) { create(:contact, account: account) }

    it 'keeps the number for whoever holds it first', :aggregate_failures do
      expect(described_class.assignable_primary?(account_id: account.id, phone: phone, contact_id: contact.id)).to be(true)

      holder = create(:contact, account: account, phone_number: phone)
      expect(described_class.assignable_primary?(account_id: account.id, phone: phone, contact_id: contact.id)).to be(false)
      expect(described_class.assignable_primary?(account_id: account.id, phone: phone, contact_id: holder.id)).to be(true)
    end

    it 'treats a chat from the number as holding it' do
      create(:contact_inbox, contact: create(:contact, account: account), inbox: whatsapp_inbox, source_id: digits)

      expect(described_class.assignable_primary?(account_id: account.id, phone: phone, contact_id: contact.id)).to be(false)
    end

    it 'reserves the number of an unresolved hidden share for its owner only', :aggregate_failures do
      owner = create(:contact, account: account, phone_number: nil)
      create(:contact, account: account, custom_attributes: share_attributes(owner_id: owner.id))

      expect(described_class.assignable_primary?(account_id: account.id, phone: phone, contact_id: contact.id)).to be(false)
      expect(described_class.assignable_primary?(account_id: account.id, phone: phone, contact_id: owner.id)).to be(true)
      expect(described_class.reservation_owner_ids(account_id: account.id, phone: phone)).to eq([owner.id])

      owner.update!(phone_number: '+77000000008')
      expect(described_class.assignable_primary?(account_id: account.id, phone: phone, contact_id: contact.id)).to be(true)
    end
  end

  describe '.card?' do
    it 'is durable and identity based', :aggregate_failures do
      expect(described_class.card?(create(:contact, account: account))).to be(false)
      expect(described_class.card?(create(:contact, account: account, custom_attributes: { described_class::CARD_KEY => true }))).to be(true)
      expect(described_class.card?(create(:contact, account: account, custom_attributes: { 'medelement_patient_code' => 'p-1' }))).to be(true)
      expect(described_class.card?(create(:contact, account: account, custom_attributes: { 'iin' => '940720300129' }))).to be(true)
      expect(described_class.card?(create(:contact, account: account, identifier: '940720300129'))).to be(true)
      expect(described_class.card?(create(:contact, account: account, identifier: 'whatsapp_web:55555@lid'))).to be(false)
    end

    it 'covers the patient of an appointment without card attributes', :aggregate_failures do
      chat = create(:contact, account: account)
      patient = create(:contact, account: account)
      create(:scheduling_appointment, account: account, contact: chat, patient_contact: patient)
      imported = create(:contact, account: account)
      create(:scheduling_appointment, account: account, contact: imported, source: 'medelement')

      expect(described_class.card?(patient)).to be(true)
      expect(described_class.card?(imported)).to be(true)
      expect(described_class.card?(chat)).to be(false)
    end
  end

  it 'masks all but the last two digits' do
    expect(described_class.mask(phone)).to eq('+7 *** ***-**-09')
  end
end
