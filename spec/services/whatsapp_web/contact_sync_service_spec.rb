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
    expect(contact_inbox.contact.additional_attributes.dig('display_preferences', 'primary_name_source')).to include(
      'kind' => 'channel_profile',
      'contact_inbox_id' => contact_inbox.id
    )
  end

  it 'treats low-trust payload display names as non-authoritative' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '15551234567@s.whatsapp.net',
        pushName: 'Operator Alias'
      },
      trust_payload_display_name: false
    ).perform

    expect(contact_inbox).to be_present
    expect(contact_inbox.contact.reload.name).to eq('+15551234567')
    expect(contact_inbox.contact.additional_attributes['last_provider_display_name']).to be_nil
    expect(contact_inbox.reload.channel_profile.display_name).to eq('+15551234567')
    expect(contact_inbox.channel_profile.profile_data['last_provider_display_name']).to be_nil
  end

  it 'imports lid-only identities as provisional contacts that can be upgraded later' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '143907392331785@lid',
        pushName: 'LID User'
      }
    ).perform

    expect(contact_inbox).to be_present
    expect(contact_inbox.source_id).to eq('143907392331785@lid')
    expect(contact_inbox.contact.phone_number).to be_nil
    expect(contact_inbox.contact.identifier).to eq('whatsapp_web:143907392331785@lid')
    expect(contact_inbox.contact.additional_attributes['canonical_jid']).to eq('143907392331785@lid')
    expect(contact_inbox.contact.additional_attributes['provisional_whatsapp_identity']).to be(true)
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

  it 'reuses a provisional lid contact when the canonical phone jid arrives later' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    provisional_contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '143907392331785@lid',
        pushName: 'Alice'
      }
    ).perform

    resolved_contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '15551234567@s.whatsapp.net',
        remoteLid: '143907392331785@lid',
        pushName: 'Alice'
      }
    ).perform

    expect(resolved_contact_inbox).to be_present
    expect(resolved_contact_inbox.contact_id).to eq(provisional_contact_inbox.contact_id)
    expect(resolved_contact_inbox.source_id).to eq('15551234567')
    expect(resolved_contact_inbox.contact.reload.phone_number).to eq('+15551234567')
    expect(resolved_contact_inbox.contact.additional_attributes['lid_jid']).to eq('143907392331785@lid')
  end

  it 'replaces a technical lid-based name with the phone number when the canonical phone jid arrives later' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    provisional_contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '249262822686958@lid',
        pushName: '249262822686958'
      }
    ).perform

    expect(provisional_contact_inbox.contact.reload.name).to eq('249262822686958@lid')

    resolved_contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '77077064008@s.whatsapp.net',
        remoteLid: '249262822686958@lid',
        pushName: '249262822686958'
      }
    ).perform

    expect(resolved_contact_inbox).to be_present
    expect(resolved_contact_inbox.contact_id).to eq(provisional_contact_inbox.contact_id)
    expect(resolved_contact_inbox.contact.reload.phone_number).to eq('+77077064008')
    expect(resolved_contact_inbox.contact.name).to eq('+77077064008')
  end

  it 'keeps the phone-based name and channel profile display name when later lid-only events arrive' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '249262822686958@lid',
        pushName: '249262822686958'
      }
    ).perform

    resolved_contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '77077064008@s.whatsapp.net',
        remoteLid: '249262822686958@lid',
        pushName: '249262822686958'
      }
    ).perform

    expect(resolved_contact_inbox.contact.reload.name).to eq('+77077064008')
    expect(resolved_contact_inbox.reload.channel_profile.display_name).to eq('+77077064008')

    lid_contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '249262822686958@lid',
        pushName: '249262822686958'
      }
    ).perform

    expect(lid_contact_inbox.contact_id).to eq(resolved_contact_inbox.contact_id)
    expect(lid_contact_inbox.contact.reload.name).to eq('+77077064008')
    expect(lid_contact_inbox.reload.channel_profile.display_name).to eq('+77077064008')
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

  it 'keeps a human-readable unicode provider name instead of treating it as a placeholder' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '77077489629@s.whatsapp.net',
        remoteLid: '129115340464278@lid',
        pushName: 'Максим'
      }
    ).perform

    expect(contact_inbox).to be_present
    expect(contact_inbox.contact.name).to eq('Максим')
    expect(contact_inbox.reload.channel_profile.display_name).to eq('Максим')
  end

  it 'restores the last known provider name when a later payload arrives without pushName' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '77077489629@s.whatsapp.net',
        remoteLid: '129115340464278@lid',
        pushName: 'Максим'
      }
    ).perform

    contact = channel.account.contacts.find_by!(phone_number: '+77077489629')
    contact.update!(
      name: '+77077489629',
      additional_attributes: contact.additional_attributes.merge(
        'last_provider_display_name' => 'Максим',
        'last_provider_display_name_recorded_at' => 1.minute.ago.iso8601
      )
    )
    contact.contact_channel_profiles.where(provider: 'whatsapp_web').first.update!(
      display_name: '+77077489629',
      profile_data: contact.contact_channel_profiles.where(provider: 'whatsapp_web').first.profile_data.merge(
        'last_provider_display_name' => 'Максим',
        'last_provider_display_name_recorded_at' => 1.minute.ago.iso8601
      )
    )

    contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '77077489629@s.whatsapp.net',
        remoteLid: '129115340464278@lid'
      }
    ).perform

    expect(contact_inbox.contact.reload.name).to eq('Максим')
    expect(contact_inbox.reload.channel_profile.display_name).to eq('Максим')
  end

  it 'does not downgrade an existing human-readable profile name when a later payload arrives without pushName' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    contact = create(
      :contact,
      account: channel.account,
      name: 'Максим',
      phone_number: '+77077489629',
      identifier: 'whatsapp_web:129115340464278@lid',
      additional_attributes: {
        'raw_jid' => '77077489629@s.whatsapp.net',
        'canonical_jid' => '77077489629@s.whatsapp.net',
        'lid_jid' => '129115340464278@lid',
        'provider' => 'whatsapp_web',
        'last_provider_display_name' => 'Максим',
        'last_provider_display_name_recorded_at' => 1.minute.ago.iso8601
      }
    )
    contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '77077489629')
    create(
      :contact_channel_profile,
      contact: contact,
      contact_inbox: contact_inbox,
      inbox: channel.inbox,
      provider: 'whatsapp_web',
      source_id: '77077489629',
      display_name: 'Максим',
      phone_number: '+77077489629',
      profile_data: {
        'identifier' => 'whatsapp_web:129115340464278@lid',
        'source_id' => '77077489629',
        'raw_jid' => '77077489629@s.whatsapp.net',
        'canonical_jid' => '77077489629@s.whatsapp.net',
        'lid_jid' => '129115340464278@lid',
        'display_name' => 'Максим',
        'name' => 'Максим',
        'phone_number' => '+77077489629',
        'last_provider_display_name' => 'Максим',
        'last_provider_display_name_recorded_at' => 1.minute.ago.iso8601
      }
    )

    described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '77077489629@s.whatsapp.net',
        remoteLid: '129115340464278@lid'
      }
    ).perform

    expect(contact.reload.name).to eq('Максим')
    expect(contact_inbox.reload.channel_profile.display_name).to eq('Максим')
  end

  it 'does not overwrite an existing human-readable profile name with a different provider name' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    contact = create(
      :contact,
      account: channel.account,
      name: 'Manual Alias',
      phone_number: '+77077489629',
      identifier: 'whatsapp_web:129115340464278@lid',
      additional_attributes: {
        'raw_jid' => '77077489629@s.whatsapp.net',
        'canonical_jid' => '77077489629@s.whatsapp.net',
        'lid_jid' => '129115340464278@lid',
        'provider' => 'whatsapp_web',
        'last_provider_display_name' => 'Manual Alias',
        'last_provider_display_name_recorded_at' => 1.minute.ago.iso8601
      }
    )
    contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '77077489629')
    create(
      :contact_channel_profile,
      contact: contact,
      contact_inbox: contact_inbox,
      inbox: channel.inbox,
      provider: 'whatsapp_web',
      source_id: '77077489629',
      display_name: 'Manual Alias',
      phone_number: '+77077489629',
      profile_data: {
        'identifier' => 'whatsapp_web:129115340464278@lid',
        'source_id' => '77077489629',
        'raw_jid' => '77077489629@s.whatsapp.net',
        'canonical_jid' => '77077489629@s.whatsapp.net',
        'lid_jid' => '129115340464278@lid',
        'display_name' => 'Manual Alias',
        'name' => 'Manual Alias',
        'phone_number' => '+77077489629',
        'last_provider_display_name' => 'Manual Alias',
        'last_provider_display_name_recorded_at' => 1.minute.ago.iso8601
      }
    )

    described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '77077489629@s.whatsapp.net',
        remoteLid: '129115340464278@lid',
        pushName: 'Максим'
      }
    ).perform

    expect(contact.reload.name).to eq('Manual Alias')
    expect(contact_inbox.reload.channel_profile.display_name).to eq('Manual Alias')
  end

  it 'falls back to the phone number when Evolution sends a generic reception name' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '77072271414@s.whatsapp.net',
        remoteLid: '134961562669211@lid',
        pushName: 'RECEPTION'
      }
    ).perform

    expect(contact_inbox).to be_present
    expect(contact_inbox.contact.name).to eq('+77072271414')
    expect(contact_inbox.reload.channel_profile.display_name).to eq('+77072271414')
  end

  it 'replaces a phone fallback with a better provider name when it arrives later' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '77072271414@s.whatsapp.net',
        remoteLid: '134961562669211@lid',
        pushName: 'RECEPTION'
      }
    ).perform

    described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '77072271414@s.whatsapp.net',
        remoteLid: '134961562669211@lid',
        pushName: 'VSETUT KAZAKHSTAN'
      }
    ).perform

    expect(contact_inbox.contact.reload.name).to eq('VSETUT KAZAKHSTAN')
    expect(contact_inbox.reload.channel_profile.display_name).to eq('VSETUT KAZAKHSTAN')
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

  it 'recovers from contact creation races when the phone number is already taken' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    existing_contact = create(:contact, account: channel.account, name: 'Existing', phone_number: '+15551234567')
    invalid_contact = channel.account.contacts.new(name: 'Alice', phone_number: '+15551234567')
    invalid_contact.valid?
    invalid_error = ActiveRecord::RecordInvalid.new(invalid_contact)

    builder = instance_double(ContactInboxWithContactBuilder)
    allow(ContactInboxWithContactBuilder).to receive(:new).and_return(builder)
    allow(builder).to receive(:perform).and_raise(invalid_error)

    contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '15551234567@s.whatsapp.net',
        pushName: 'Alice'
      }
    ).perform

    expect(contact_inbox).to be_present
    expect(contact_inbox.contact_id).to eq(existing_contact.id)
    expect(contact_inbox.source_id).to eq('15551234567')
    expect(existing_contact.reload.name).to eq('Existing')
    expect(existing_contact.reload.additional_attributes).to include(
      'provider' => 'whatsapp_web',
      'canonical_jid' => '15551234567@s.whatsapp.net',
      'raw_jid' => '15551234567@s.whatsapp.net'
    )
  end

  it 'reuses a shared cross-channel contact without overwriting another provider profile' do
    telegram_channel = create(:channel_telegram_personal, account: channel.account)
    shared_contact = create(
      :contact,
      account: channel.account,
      name: 'Shared Contact',
      phone_number: '+15551234567',
      identifier: 'telegram_personal:23',
      additional_attributes: {
        'provider' => 'telegram_personal',
        'profile_photo_url' => 'https://cdn.example.com/tg-avatar.jpg',
        'social_telegram_user_id' => 23
      }
    )
    create(:contact_inbox, inbox: telegram_channel.inbox, contact: shared_contact, source_id: '23')

    expect(Avatar::AvatarFromUrlJob).not_to receive(:perform_later)

    contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '15551234567@s.whatsapp.net',
        pushName: 'Alice',
        profilePicUrl: 'https://cdn.example.com/wa-avatar.jpg'
      }
    ).perform

    expect(contact_inbox.contact).to eq(shared_contact)
    expect(shared_contact.reload.name).to eq('Shared Contact')
    expect(shared_contact.reload.identifier).to eq('telegram_personal:23')
    expect(shared_contact.additional_attributes).to include(
      'provider' => 'telegram_personal',
      'profile_photo_url' => 'https://cdn.example.com/tg-avatar.jpg',
      'social_telegram_user_id' => 23
    )
    expect(shared_contact.additional_attributes).not_to include(
      'canonical_jid' => '15551234567@s.whatsapp.net',
      'raw_jid' => '15551234567@s.whatsapp.net'
    )
    expect(shared_contact.additional_attributes.dig('channel_profiles', 'whatsapp_web')).to be_present
    expect(shared_contact.additional_attributes.dig('channel_profiles', 'whatsapp_web').values.first).to include(
      'source_id' => '15551234567',
      'canonical_jid' => '15551234567@s.whatsapp.net',
      'profile_pic_url' => 'https://cdn.example.com/wa-avatar.jpg',
      'provider' => 'whatsapp_web'
    )
  end

  it 'does not auto-claim the primary name source for a shared contact when the same name already exists' do
    telegram_channel = create(:channel_telegram_personal, account: channel.account)
    shared_contact = create(
      :contact,
      account: channel.account,
      name: 'Arman',
      phone_number: '+15551234567',
      identifier: 'telegram_personal:23',
      additional_attributes: {
        'provider' => 'telegram_personal',
        'social_telegram_user_id' => 23
      }
    )
    create(:contact_inbox, inbox: telegram_channel.inbox, contact: shared_contact, source_id: '23')

    described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '15551234567@s.whatsapp.net',
        pushName: 'Arman'
      }
    ).perform

    expect(shared_contact.reload.name).to eq('Arman')
    expect(shared_contact.additional_attributes.dig('display_preferences', 'primary_name_source')).to be_blank
  end

  it 'merges a provisional lid contact into an existing phone contact when the phone number is already taken' do
    telegram_channel = create(:channel_telegram_personal, account: channel.account)
    shared_contact = create(
      :contact,
      account: channel.account,
      name: 'Shared Contact',
      phone_number: '+77077064008',
      identifier: 'telegram_personal:23',
      additional_attributes: {
        'provider' => 'telegram_personal',
        'profile_photo_url' => 'https://cdn.example.com/tg-avatar.jpg',
        'social_telegram_user_id' => 23
      }
    )
    create(:contact_inbox, inbox: telegram_channel.inbox, contact: shared_contact, source_id: '23')

    provisional_contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '249262822686958@lid',
        pushName: 'Alice'
      }
    ).perform

    expect(Avatar::AvatarFromUrlJob).not_to receive(:perform_later)

    resolved_contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '77077064008@s.whatsapp.net',
        remoteLid: '249262822686958@lid',
        pushName: 'Alice',
        profilePicUrl: 'https://cdn.example.com/wa-avatar.jpg'
      }
    ).perform

    expect(resolved_contact_inbox).to be_present
    expect(resolved_contact_inbox.contact_id).to eq(shared_contact.id)
    expect(resolved_contact_inbox.reload.contact).to eq(shared_contact)
    expect(Contact.find_by(id: provisional_contact_inbox.contact_id)).to be_nil
    expect(channel.inbox.contact_inboxes.find_by(source_id: '249262822686958@lid')&.contact_id).to eq(shared_contact.id)
    expect(channel.inbox.contact_inboxes.find_by(source_id: '77077064008')&.contact_id).to eq(shared_contact.id)

    expect(shared_contact.reload.identifier).to eq('telegram_personal:23')
    expect(shared_contact.additional_attributes).to include(
      'provider' => 'telegram_personal',
      'profile_photo_url' => 'https://cdn.example.com/tg-avatar.jpg',
      'social_telegram_user_id' => 23
    )
    expect(shared_contact.additional_attributes.dig('channel_profiles', 'whatsapp_web')).to be_present
    expect(shared_contact.additional_attributes.dig('channel_profiles', 'whatsapp_web').values.first).to include(
      'source_id' => '77077064008',
      'canonical_jid' => '77077064008@s.whatsapp.net',
      'provider' => 'whatsapp_web'
    )
  end
end
