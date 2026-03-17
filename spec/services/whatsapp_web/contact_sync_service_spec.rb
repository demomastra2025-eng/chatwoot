require 'rails_helper'

RSpec.describe WhatsappWeb::ContactSyncService do
  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  let(:channel) { create(:channel_whatsapp_web) }

  it 'imports personal whatsapp jids as contacts' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '15551234567@s.whatsapp.net',
        pushName: 'Alice'
      }
    ).perform

    expect(contact_inbox).to be_present
    expect(contact_inbox.source_id).to eq('15551234567')
    expect(contact_inbox.contact.phone_number).to eq('+15551234567')
  end

  it 'skips lid-only identities that do not map to a canonical phone jid' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '143907392331785@lid',
        pushName: 'LID User'
      }
    ).perform

    expect(contact_inbox).to be_nil
    expect(channel.inbox.contact_inboxes).to be_empty
  end

  it 'imports lid identities when Evolution provides a canonical phone jid alternative' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '143907392331785@lid',
        remoteJidAlt: '15551234567@s.whatsapp.net',
        pushName: 'Alice'
      }
    ).perform

    expect(contact_inbox).to be_present
    expect(contact_inbox.source_id).to eq('15551234567')
    expect(contact_inbox.contact.phone_number).to eq('+15551234567')
    expect(contact_inbox.contact.additional_attributes['raw_jid']).to eq('143907392331785@lid')
    expect(contact_inbox.contact.additional_attributes['canonical_jid']).to eq('15551234567@s.whatsapp.net')
  end

  it 'skips invalid zero phone jids' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '0@s.whatsapp.net',
        pushName: 'Zero'
      }
    ).perform

    expect(contact_inbox).to be_nil
    expect(channel.inbox.contact_inboxes).to be_empty
  end

  it 'falls back to the phone number when Evolution sends the placeholder self-name' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '15551234567@s.whatsapp.net',
        pushName: 'Você'
      }
    ).perform

    expect(contact_inbox).to be_present
    expect(contact_inbox.contact.name).to eq('+15551234567')
  end

  it 'replaces an existing placeholder self-name with the phone number' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    existing_contact = create(:contact, account: channel.account, name: 'Você', phone_number: '+15551234567')
    create(:contact_inbox, inbox: channel.inbox, contact: existing_contact, source_id: '15551234567')

    contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '15551234567@s.whatsapp.net',
        pushName: 'Você'
      }
    ).perform

    expect(contact_inbox.contact.reload.name).to eq('+15551234567')
  end

  it 'schedules avatar sync when profilePicUrl is present for new contacts' do
    expect(Avatar::AvatarFromUrlJob).to receive(:perform_later).with(
      instance_of(Contact),
      'https://cdn.example.com/avatar.jpg'
    )

    described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '15551234567@s.whatsapp.net',
        pushName: 'Alice',
        profilePicUrl: 'https://cdn.example.com/avatar.jpg'
      }
    ).perform
  end

  it 'schedules avatar sync when profilePicUrl changes for an existing contact' do
    existing_contact = create(:contact, account: channel.account, name: 'Alice', phone_number: '+15551234567')
    create(:contact_inbox, inbox: channel.inbox, contact: existing_contact, source_id: '15551234567')

    expect(Avatar::AvatarFromUrlJob).to receive(:perform_later).with(
      existing_contact,
      'https://cdn.example.com/avatar-2.jpg'
    )

    described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '15551234567@s.whatsapp.net',
        pushName: 'Alice',
        profilePicUrl: 'https://cdn.example.com/avatar-2.jpg'
      }
    ).perform

    expect(existing_contact.reload.additional_attributes['profile_pic_url']).to eq('https://cdn.example.com/avatar-2.jpg')
  end
end
