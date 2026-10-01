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

  it 'never absorbs a communication owner without a phone into the patient card that took the booking phone', :aggregate_failures do
    account.enable_features!('scheduling')
    policy = Integrations::Medelement::AppointmentPatientIdentity
    owner = create(:contact, account: account, name: 'Mother', phone_number: nil, identifier: 'telegram_personal:55555')
    owner_source = create(:contact_inbox, contact: owner, inbox: channel.inbox, source_id: '55555')
    conversation = create(:conversation, account: account, inbox: channel.inbox, contact: owner, contact_inbox: owner_source)
    create(:message, account: account, inbox: channel.inbox, conversation: conversation, sender: owner, message_type: :incoming)
    appointment = create(:scheduling_appointment, account: account, contact: owner, conversation: conversation,
                                                  client_first_name: 'Child', client_last_name: 'Patient', client_middle_name: nil,
                                                  client_name: 'Child Patient', client_phone: '+77000000009', client_identifier: nil,
                                                  custom_attributes: { policy::OWNED_IDENTITY_KEY => true, policy::EXPLICIT_IDENTIFIER_KEY => true })
    appointment.with_lock do
      Integrations::Medelement::PatientContactBinding.new(appointment: appointment).prepare!(patient_code: 'child-2')
      appointment.save!
    end
    card = appointment.reload.patient_contact
    # Owner model 2026-09-29 (M2): the card has the family number only as доп. номер shared from the booking chat.
    expect(card).to have_attributes(phone_number: nil)
    expect(card.custom_attributes['secondary_phones']).to eq(['+77000000009'])

    described_class.new(inbox: channel.inbox, params: { peer_user_id: '55555', chat_id: '55555', first_name: 'Mother',
                                                        phone_number: '77000000009', sync_source: 'saved_contact' }).perform

    expect(Contact.exists?(owner.id)).to be(true)
    expect(owner.reload.phone_number).to eq('+77000000009')
    expect(card.reload.phone_number).to be_nil
    expect(conversation.reload.contact_id).to eq(owner.id)
    expect(owner_source.reload.contact_id).to eq(owner.id)
    expect(appointment.reload).to have_attributes(contact_id: owner.id, patient_contact_id: card.id)
    expect(card.reload.custom_attributes['medelement_patient_code']).to eq('child-2')
  end

  it 'preserves separate patient cards and existing inbound authorship on a shared-phone collision' do
    owner = create(:contact, account: account, name: 'Primary', phone_number: '+77000000001',
                             custom_attributes: { 'medelement_patient_code' => 'primary-1' })
    patient = create(:contact, account: account, name: 'Relative', phone_number: nil, identifier: 'telegram_personal:99999',
                               custom_attributes: { 'medelement_patient_code' => 'relative-2', 'medelement_patient_card' => true })
    source = create(:contact_inbox, inbox: channel.inbox, contact: patient, source_id: '99999')
    conversation = create(:conversation, account: account, inbox: channel.inbox, contact: patient, contact_inbox: source)
    message = create(:message, account: account, inbox: channel.inbox, conversation: conversation, sender: patient, message_type: :incoming)
    result = described_class.new(inbox: channel.inbox, params: { peer_user_id: '99999', chat_id: '99999',
                                                                 first_name: 'Relative', phone_number: '77000000001',
                                                                 sync_source: 'saved_contact' }).perform
    expect(result.contact_id).to eq(patient.id)
    expect(source.reload).to have_attributes(contact_id: patient.id, source_id: '99999')
    expect(message.reload.sender_id).to eq(patient.id)
    expect(owner.reload).to have_attributes(name: 'Primary', phone_number: '+77000000001')
    expect(patient.reload).to have_attributes(phone_number: nil)
    expect(patient.custom_attributes['medelement_patient_code']).to eq('relative-2')
  end

  it 'locks bound patient appointments before a channel merge re-checks the patient guard' do
    source = create(:contact, account: channel.account, phone_number: nil)
    target = create(:contact, account: channel.account, phone_number: '+77000000009')
    guard = Contacts::PatientIdentityMergeGuard
    allow(guard).to receive(:lock_patient_bindings!).and_call_original
    allow(guard).to receive(:allowed?).and_return(false)
    service = described_class.new(inbox: channel.inbox, params: { peer_user_id: '99998', chat_id: '99998', first_name: 'Duplicate' })

    ActiveRecord::Base.transaction { service.send(:merge_contact_records!, source_contact: source, target_contact: target) }

    expect(guard).to have_received(:lock_patient_bindings!).with(source, target).ordered
    expect(guard).to have_received(:allowed?).with(source_contact: source, target_contact: target).ordered
    expect(Contact.exists?(source.id)).to be(true)
  end

  def create_reminder_for_contact_inbox(contact_inbox)
    conversation = create(
      :conversation, account: contact_inbox.contact.account, inbox: contact_inbox.inbox,
                     contact: contact_inbox.contact, contact_inbox: contact_inbox
    )
    create(:reminder, account: contact_inbox.contact.account, touch_conversation: conversation)
  end

  def expect_reminder_reassigned(reminder, target_contact, original_fingerprint, contact_inbox:)
    expect(contact_inbox.reload.contact).to eq(target_contact)
    reminder.reload
    expect(reminder.target_contact).to eq(target_contact)
    expect(reminder.fingerprint).not_to eq(original_fingerprint)
    duplicate_reminder = reminder.dup
    expect(duplicate_reminder).not_to be_valid
    expect(duplicate_reminder.errors[:base]).to include('An open touch with the same content already exists')
  end

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
    original_reminder_fingerprint = (reminder = create_reminder_for_contact_inbox(contact_inbox)).fingerprint

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

    expect_reminder_reassigned(reminder, shared_contact, original_reminder_fingerprint, contact_inbox: contact_inbox)
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
