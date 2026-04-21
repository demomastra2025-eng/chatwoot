require 'rails_helper'
require 'stringio'

RSpec.describe TelegramPersonal::ContactSyncService do
  include ActiveJob::TestHelper

  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }
  let(:channel) { create(:channel_telegram_personal, account: account, phone_number: '+77066318623') }

  it 'creates a stable telegram personal contact profile and contact inbox' do
    contact_inbox = nil

    expect do
      contact_inbox = described_class.new(
        inbox: channel.inbox,
        params: {
          peer_user_id: '23',
          chat_id: '23',
          first_name: 'Sojan',
          last_name: 'Jose',
          username: 'sojan',
          phone_number: '77066318623',
          language_code: 'en',
          avatar_url: 'https://chatwoot-assets.local/avatar.png',
          avatar_fingerprint: 'telegram-photo-23',
          is_contact: true,
          is_mutual_contact: true,
          is_premium: false,
          sync_source: 'private_dialog',
          last_message_at: '2026-04-08T10:15:30Z',
          unread_count: 4
        }
      ).perform
    end.to have_enqueued_job(TelegramPersonal::SyncProfileAvatarJob)

    contact = contact_inbox.contact

    expect(contact_inbox.source_id).to eq('23')
    expect(contact.name).to eq('Sojan Jose')
    expect(contact.identifier).to eq('telegram_personal:23')
    expect(contact.phone_number).to eq('+77066318623')
    expect(contact.last_activity_at.iso8601).to eq('2026-04-08T10:15:30Z')
    expect(contact.additional_attributes).to include(
      'provider' => 'telegram_personal',
      'social_telegram_user_id' => 23,
      'social_telegram_user_name' => 'sojan',
      'username' => 'sojan',
      'language_code' => 'en',
      'phone_number' => '+77066318623',
      'sync_source' => 'private_dialog',
      'last_message_at' => '2026-04-08T10:15:30Z',
      'unread_count' => 4,
      'is_contact' => true,
      'is_mutual_contact' => true,
      'is_premium' => false
    )
    expect(contact.additional_attributes.dig('channel_profiles', 'telegram_personal', 'telegram_personal:23')).to include(
      'identifier' => 'telegram_personal:23',
      'source_id' => '23',
      'inbox_id' => channel.inbox.id,
      'peer_user_id' => 23,
      'username' => 'sojan',
      'avatar_fingerprint' => 'telegram-photo-23'
    )
    expect(contact.additional_attributes).not_to have_key('profile_photo_url')

    profile = contact_inbox.reload.channel_profile
    expect(enqueued_jobs.last[:args]).to eq([profile.id, 'telegram-photo-23'])
    expect(profile.stored_avatar_url).to be_nil
    expect(profile.profile_data).not_to have_key('profile_photo_url')
    expect(profile.push_event_data[:avatar_url]).to be_nil
    expect(profile.push_event_data[:profile_data]).not_to have_key('profile_photo_url')
  end

  it 'replaces technical placeholder names with richer telegram profile data' do
    contact = create(
      :contact,
      account: account,
      name: '23',
      identifier: 'telegram_personal:23'
    )
    create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '23')

    described_class.new(
      inbox: channel.inbox,
      params: {
        peer_user_id: '23',
        first_name: 'Sojan',
        last_name: 'Jose',
        username: 'sojan'
      }
    ).perform

    expect(contact.reload.name).to eq('Sojan Jose')
  end

  it 'does not fail contact sync when avatar enqueue is unavailable' do
    allow(TelegramPersonal::SyncProfileAvatarJob).to receive(:perform_later).and_raise(StandardError, 'redis unavailable')

    contact_inbox = nil
    expect do
      contact_inbox = described_class.new(
        inbox: channel.inbox,
        params: {
          peer_user_id: '23',
          first_name: 'Sojan',
          username: 'sojan',
          avatar_url: 'https://chatwoot-assets.local/avatar.png',
          avatar_fingerprint: 'telegram-photo-23'
        }
      ).perform
    end.not_to raise_error

    expect(contact_inbox.source_id).to eq('23')
    expect(contact_inbox.contact.name).to eq('Sojan')
  end

  it 'reuses an existing cross-channel contact without overwriting shared provider metadata' do
    whatsapp_channel = create(:channel_whatsapp_web, account: account)
    contact = create(
      :contact,
      account: account,
      name: 'Shared Contact',
      phone_number: '+77066318623',
      identifier: 'whatsapp_web:77066318623@lid',
      additional_attributes: {
        'provider' => 'whatsapp_web',
        'profile_photo_url' => 'https://chatwoot-assets.local/wa-avatar.png',
        'raw_jid' => '77066318623@lid'
      }
    )
    create(:contact_inbox, inbox: whatsapp_channel.inbox, contact: contact, source_id: '77066318623@lid')

    contact_inbox = nil

    expect do
      contact_inbox = described_class.new(
        inbox: channel.inbox,
        params: {
          peer_user_id: '23',
          first_name: 'Sojan',
          last_name: 'Jose',
          username: 'sojan',
          phone_number: '77066318623',
          avatar_url: 'https://chatwoot-assets.local/tg-avatar.png',
          avatar_fingerprint: 'telegram-photo-23',
          sync_source: 'private_dialog'
        }
      ).perform
    end.to have_enqueued_job(TelegramPersonal::SyncProfileAvatarJob)

    expect(contact_inbox.contact).to eq(contact)
    expect(contact.reload.identifier).to eq('whatsapp_web:77066318623@lid')
    expect(contact.additional_attributes).to include(
      'provider' => 'whatsapp_web',
      'profile_photo_url' => 'https://chatwoot-assets.local/wa-avatar.png',
      'raw_jid' => '77066318623@lid',
      'social_telegram_user_id' => 23,
      'social_telegram_user_name' => 'sojan'
    )
    expect(contact.additional_attributes).not_to include(
      'username' => 'sojan'
    )
    expect(contact.additional_attributes.dig('channel_profiles', 'telegram_personal', 'telegram_personal:23')).to include(
      'identifier' => 'telegram_personal:23',
      'source_id' => '23',
      'inbox_id' => channel.inbox.id,
      'username' => 'sojan',
      'avatar_fingerprint' => 'telegram-photo-23'
    )

    profile = contact_inbox.reload.channel_profile
    expect(enqueued_jobs.last[:args]).to eq([profile.id, 'telegram-photo-23'])
    expect(profile.stored_avatar_url).to be_nil
    expect(profile.profile_data).not_to have_key('profile_photo_url')
  end

  it 'merges an existing telegram contact into the shared phone contact instead of failing on unique phone number' do
    shared_contact = create(
      :contact,
      account: account,
      name: 'Shared Contact',
      phone_number: '+77475318623',
      identifier: 'whatsapp_web:77475318623@lid',
      additional_attributes: {
        'provider' => 'whatsapp_web',
        'profile_photo_url' => 'https://chatwoot-assets.local/wa-avatar.png',
        'raw_jid' => '77475318623@lid'
      }
    )

    telegram_contact = create(
      :contact,
      account: account,
      name: '134527512',
      identifier: 'telegram_personal:134527512'
    )
    contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: telegram_contact, source_id: '134527512')

    expect do
      described_class.new(
        inbox: channel.inbox,
        params: {
          peer_user_id: '134527512',
          chat_id: '134527512',
          first_name: 'Мой',
          last_name: 'Теле2',
          username: 'Bakhitov',
          phone_number: '77475318623',
          sync_source: 'saved_contact'
        }
      ).perform
    end.not_to raise_error

    expect(contact_inbox.reload.contact).to eq(shared_contact)
    expect { telegram_contact.reload }.to raise_error(ActiveRecord::RecordNotFound)
    expect(shared_contact.reload.additional_attributes).to include(
      'provider' => 'whatsapp_web',
      'profile_photo_url' => 'https://chatwoot-assets.local/wa-avatar.png',
      'raw_jid' => '77475318623@lid',
      'social_telegram_user_id' => 134_527_512,
      'social_telegram_user_name' => 'Bakhitov'
    )
    expect(shared_contact.additional_attributes.dig('channel_profiles', 'telegram_personal', 'telegram_personal:134527512')).to include(
      'identifier' => 'telegram_personal:134527512',
      'source_id' => '134527512',
      'phone_number' => '+77475318623'
    )
  end

  it 'does not overwrite an existing contact with the channel owner profile from message events and repairs the channel profile' do
    contact = create(
      :contact,
      account: account,
      name: 'Мой Теле2',
      phone_number: '+77475318623',
      identifier: 'telegram_personal:134527512',
      additional_attributes: {
        'provider' => 'telegram_personal'
      }
    )
    contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '134527512')
    create(
      :contact_channel_profile,
      contact_inbox: contact_inbox,
      contact: contact,
      inbox: channel.inbox,
      account: account,
      provider: 'telegram_personal',
      source_id: '134527512',
      display_name: 'One link Менеджер',
      username: 'Bakhitov',
      phone_number: '+77066318623',
      avatar_url: 'https://chatwoot-assets.local/self-avatar.png',
      profile_data: {
        'identifier' => 'telegram_personal:134527512',
        'source_id' => '134527512',
        'display_name' => 'One link Менеджер',
        'first_name' => 'One link',
        'last_name' => 'Менеджер',
        'username' => 'Bakhitov',
        'phone_number' => '+77066318623',
        'profile_photo_url' => 'https://chatwoot-assets.local/self-avatar.png'
      }
    )

    described_class.new(
      inbox: channel.inbox,
      params: {
        peer_user_id: '134527512',
        chat_id: '134527512',
        first_name: 'One link',
        last_name: 'Менеджер',
        username: 'Bakhitov',
        phone_number: '77066318623',
        avatar_url: 'https://chatwoot-assets.local/self-avatar.png',
        avatar_fingerprint: 'telegram-self-photo',
        sync_source: 'message_event'
      }
    ).perform

    expect(contact.reload.name).to eq('Мой Теле2')
    expect(contact.phone_number).to eq('+77475318623')
    expect(contact.additional_attributes['social_telegram_user_id']).to eq(134_527_512)
    expect(contact.additional_attributes['channel_profiles'].dig('telegram_personal', 'telegram_personal:134527512')).not_to include(
      'first_name' => 'One link',
      'last_name' => 'Менеджер',
      'phone_number' => '+77066318623',
      'username' => 'Bakhitov'
    )

    profile = contact_inbox.reload.channel_profile
    expect(profile.display_name).to eq('Мой Теле2')
    expect(profile.phone_number).to eq('+77475318623')
    expect(profile.username).to be_nil
    expect(profile.avatar_url).to be_nil
    expect(profile.profile_data).not_to include(
      'display_name' => 'One link Менеджер',
      'first_name' => 'One link',
      'last_name' => 'Менеджер',
      'phone_number' => '+77066318623',
      'username' => 'Bakhitov'
    )
    expect(profile.profile_data).not_to have_key('avatar_fingerprint')
  end

  it 'does not re-enqueue profile avatar download when the fingerprint is unchanged' do
    contact = create(
      :contact,
      account: account,
      name: 'Sojan Jose',
      identifier: 'telegram_personal:23',
      additional_attributes: {
        'provider' => 'telegram_personal'
      }
    )
    contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '23')
    profile = create(
      :contact_channel_profile,
      contact_inbox: contact_inbox,
      contact: contact,
      inbox: channel.inbox,
      account: account,
      provider: 'telegram_personal',
      source_id: '23',
      profile_data: {
        'identifier' => 'telegram_personal:23',
        'source_id' => '23',
        'avatar_fingerprint' => 'telegram-photo-23'
      }
    )
    profile.avatar.attach(
      io: StringIO.new(File.binread(Rails.root.join('spec/assets/avatar.png'))),
      filename: 'avatar.png',
      content_type: 'image/png'
    )

    expect do
      described_class.new(
        inbox: channel.inbox,
        params: {
          peer_user_id: '23',
          first_name: 'Sojan',
          last_name: 'Jose',
          username: 'sojan',
          avatar_url: 'https://app.one-link.kz/telegram-personal/media/avatar-23?token=old',
          avatar_fingerprint: 'telegram-photo-23',
          sync_source: 'private_dialog'
        }
      ).perform
    end.not_to have_enqueued_job(TelegramPersonal::SyncProfileAvatarJob)
  end

  it 'clears a stale avatar fingerprint when telegram no longer provides a profile photo' do
    contact = create(
      :contact,
      account: account,
      name: 'Sojan Jose',
      identifier: 'telegram_personal:23',
      additional_attributes: {
        'provider' => 'telegram_personal'
      }
    )
    contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '23')
    profile = create(
      :contact_channel_profile,
      contact_inbox: contact_inbox,
      contact: contact,
      inbox: channel.inbox,
      account: account,
      provider: 'telegram_personal',
      source_id: '23',
      profile_data: {
        'identifier' => 'telegram_personal:23',
        'source_id' => '23',
        'avatar_fingerprint' => 'telegram-photo-23'
      }
    )
    profile.avatar.attach(
      io: StringIO.new(File.binread(Rails.root.join('spec/assets/avatar.png'))),
      filename: 'avatar.png',
      content_type: 'image/png'
    )

    expect do
      described_class.new(
        inbox: channel.inbox,
        params: {
          peer_user_id: '23',
          first_name: 'Sojan',
          last_name: 'Jose',
          username: 'sojan',
          sync_source: 'private_dialog'
        }
      ).perform
    end.not_to have_enqueued_job(TelegramPersonal::SyncProfileAvatarJob)

    expect(profile.reload.profile_data).not_to have_key('avatar_fingerprint')
  end
end
