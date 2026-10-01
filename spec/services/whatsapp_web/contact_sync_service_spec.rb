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

  it 'never absorbs a LID-only communication owner into the patient card that took the booking phone', :aggregate_failures do
    account = channel.account.tap { |record| record.enable_features!('scheduling') }
    policy = Integrations::Medelement::AppointmentPatientIdentity
    owner = create(:contact, account: account, name: 'Mother', phone_number: nil, identifier: 'whatsapp_web:55555@lid')
    owner_source = create(:contact_inbox, contact: owner, inbox: channel.inbox, source_id: '55555@lid')
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
    expect(card.id).not_to eq(owner.id)

    described_class.new(channel: channel, contact_payload: { remoteJid: '77000000009@s.whatsapp.net', remoteLid: '55555@lid',
                                                             pushName: 'Mother' }).perform

    expect(Contact.exists?(owner.id)).to be(true)
    expect(owner.reload.phone_number).to eq('+77000000009')
    expect(conversation.reload.contact_id).to eq(owner.id)
    expect(owner_source.reload.contact_id).to eq(owner.id)
    expect(appointment.reload).to have_attributes(contact_id: owner.id, patient_contact_id: card.id)
    expect(card.reload).to have_attributes(phone_number: nil)
    expect(card.custom_attributes).to include('medelement_patient_code' => 'child-2', 'secondary_phones' => ['+77000000009'],
                                              Contacts::SharedPhone::SHARED_OWNER_KEY => owner.id)
  end

  context 'with a patient card that owns the phone-JID chat and a LID-only duplicate of the same WhatsApp account' do
    let(:account) { channel.account.tap { |record| record.update!(locale: 'ru') } }
    let(:mother) do
      create(:contact, account: account, name: 'Mother', phone_number: '+77000000009', custom_attributes: { 'medelement_patient_code' => 'mother-1' })
    end
    let(:lid_contact) { create(:contact, account: account, name: 'Mother LID', phone_number: nil, identifier: 'whatsapp_web:66666@lid') }
    let!(:phone_source) { create(:contact_inbox, contact: mother, inbox: channel.inbox, source_id: '77000000009') }
    let!(:lid_source) { create(:contact_inbox, contact: lid_contact, inbox: channel.inbox, source_id: '66666@lid') }
    let!(:lid_conversation) { create(:conversation, account: account, inbox: channel.inbox, contact: lid_contact, contact_inbox: lid_source) }

    before do
      # The M7x move with history transfer switched on (it ships off, see Contacts::SharedPhoneSwitches).
      enable_shared_phone_switches!
      create(:message, account: account, inbox: channel.inbox, conversation: lid_conversation, sender: lid_contact, message_type: :incoming)
    end

    def resolved_payload!
      payload = { remoteJid: '77000000009@s.whatsapp.net', remoteLid: '66666@lid', pushName: 'Mother' }
      described_class.new(channel: channel, contact_payload: payload).perform
    end

    it 'M7x moves the proven LID chat to the card as a logged transfer and never merges the contacts', :aggregate_failures do
      resolved_payload!
      later = described_class.new(channel: channel, contact_payload: { remoteJid: '66666@lid', pushName: 'Mother' }).perform

      expect([lid_source.reload.contact_id, lid_conversation.reload.contact_id, later.contact_id]).to all(eq(mother.id))
      expect(lid_conversation.messages.incoming.pluck(:sender_id)).to eq([mother.id])
      expect(phone_source.reload.contact_id).to eq(mother.id)
      expect(mother.reload.identifier).to eq('whatsapp_web:66666@lid')
      expect(Contact.exists?(lid_contact.id)).to be(true)
      expect(lid_contact.reload.identifier).to be_nil
      entry = mother.custom_attributes[Contacts::SharedPhone::TRANSFERS_KEY].first
      expect(entry).to include('basis' => 'whatsapp_account', 'direction' => 'in', 'contact_inbox_ids' => [lid_source.id])
      expect(entry['counterpart_contact_id']).to eq(lid_contact.id)
      expect(lid_conversation.messages.activity.last.content).to include('WhatsApp', 'Mother LID', '+7 *** ***-**-09')
    end

    it 'keeps a LID contact that is itself a patient card separate', :aggregate_failures do
      lid_contact.update!(custom_attributes: { 'medelement_patient_code' => 'other-1' })
      resolved_payload!

      expect([lid_source.reload.contact_id, lid_conversation.reload.contact_id]).to all(eq(lid_contact.id))
      expect(lid_contact.reload.identifier).to eq('whatsapp_web:66666@lid')
      expect(mother.reload.custom_attributes).not_to have_key(Contacts::SharedPhone::TRANSFERS_KEY)
    end

    def lid_chat_state
      { chat: [lid_source.reload.contact_id, lid_conversation.reload.contact_id], senders: lid_conversation.messages.incoming.pluck(:sender_id),
        lid_identifier: lid_contact.reload.identifier, card_identifier: mother.reload.identifier,
        card_log: mother.custom_attributes.key?(Contacts::SharedPhone::TRANSFERS_KEY) }
    end

    def expect_lid_chat_untouched
      expect(lid_chat_state).to eq(chat: [lid_contact.id, lid_contact.id], senders: [lid_contact.id], lid_identifier: 'whatsapp_web:66666@lid',
                                   card_identifier: nil, card_log: false)
    end

    # sc8rv1 M7x-a / M7x-b: staff changed the card's phone; it only keeps its old own-route phone-JID chat.
    it 'M7x-a keeps both contacts when the number is now another contact primary number', :aggregate_failures do
      mother.update!(phone_number: '+77000000061')
      lid_contact.update!(phone_number: '+77000000009')
      resolved_payload!

      expect_lid_chat_untouched
    end

    it 'M7x-b keeps both contacts when nobody holds the number as primary any more', :aggregate_failures do
      mother.update!(phone_number: '+77000000061')
      resolved_payload!

      expect_lid_chat_untouched
    end

    it 'M7x-k moves nothing while history transfer is switched off, and still stores the payload', :aggregate_failures do
      disable_shared_phone_switches!(Contacts::SharedPhoneSwitches::HISTORY_TRANSFER)
      contact_inbox = resolved_payload!

      expect_lid_chat_untouched
      expect(contact_inbox).to eq(phone_source)
    end

    it 'moves nothing with the shipped defaults (every switch off)', :aggregate_failures do
      disable_shared_phone_switches!
      resolved_payload!

      expect_lid_chat_untouched
      expect(Contact.exists?(lid_contact.id)).to be(true)
    end
  end

  it 'keeps the identity update on the source contact when the locked merge re-check refuses', :aggregate_failures do
    account = channel.account
    source_contact = create(:contact, account: account, name: 'Mother', phone_number: nil, identifier: 'whatsapp_web:55555@lid')
    source_inbox = create(:contact_inbox, contact: source_contact, inbox: channel.inbox, source_id: '55555@lid')
    phone_holder = create(:contact, account: account, name: 'Phone Holder', phone_number: '+77000000009')
    # A provider write starts between the unlocked pre-check and the re-check under the binding locks.
    allow(Contacts::PatientIdentityMergeGuard).to receive(:allowed?).and_return(true, false)

    result = described_class.new(channel: channel, contact_payload: { remoteJid: '77000000009@s.whatsapp.net', remoteLid: '55555@lid',
                                                                      pushName: 'Mother' }).perform

    expect(Contact.exists?(source_contact.id)).to be(true)
    expect(result.contact_id).to eq(source_contact.id)
    expect(source_inbox.reload.contact_id).to eq(source_contact.id)
    expect(source_contact.reload.phone_number).to be_nil
    expect(phone_holder.reload).to have_attributes(name: 'Phone Holder', phone_number: '+77000000009')
    expect(phone_holder.additional_attributes.to_h.dig('channel_profiles', 'whatsapp_web')).to be_blank
  end

  it 'keeps the existing shared source on the first patient and does not merge a second patient identity' do
    owner = create(:contact, account: channel.account, name: 'Primary', phone_number: '+77000000001',
                             custom_attributes: { 'medelement_patient_code' => 'primary-1' })
    patient = create(:contact, account: channel.account, name: 'Relative', phone_number: nil,
                               identifier: 'whatsapp_web:99999@lid',
                               custom_attributes: { 'medelement_patient_code' => 'relative-2', 'medelement_patient_card' => true })
    source = create(:contact_inbox, inbox: channel.inbox, contact: owner, source_id: '77000000001')
    conversation = create(:conversation, account: channel.account, inbox: channel.inbox, contact: owner, contact_inbox: source)
    message = create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, sender: owner, message_type: :incoming)
    result = described_class.new(channel: channel, contact_payload: { remoteJid: '77000000001@s.whatsapp.net', remoteLid: '99999@lid',
                                                                      pushName: 'Primary' }).perform
    expect(result.contact_id).to eq(owner.id)
    expect(source.reload).to have_attributes(contact_id: owner.id, source_id: '77000000001')
    expect(message.reload.sender_id).to eq(owner.id)
    expect(patient.reload.custom_attributes['medelement_patient_code']).to eq('relative-2')
    expect(owner.reload.phone_number).to eq('+77000000001')
  end

  it 'locks bound patient appointments before a channel merge re-checks the patient guard' do
    source = create(:contact, account: channel.account, phone_number: nil)
    target = create(:contact, account: channel.account, phone_number: '+77000000009')
    guard = Contacts::PatientIdentityMergeGuard
    allow(guard).to receive(:lock_patient_bindings!).and_call_original
    allow(guard).to receive(:allowed?).and_return(false)
    service = described_class.new(channel: channel, contact_payload: { remoteJid: '77000000009@s.whatsapp.net', pushName: 'Duplicate' })

    ActiveRecord::Base.transaction { service.send(:merge_contact_records!, source_contact: source, target_contact: target) }

    expect(guard).to have_received(:lock_patient_bindings!).with(source, target).ordered
    expect(guard).to have_received(:allowed?).with(source_contact: source, target_contact: target).ordered
    expect(Contact.exists?(source.id)).to be(true)
  end

  it 'moves an open appointment touch with its appointment when a channel merge absorbs the chat contact' do
    source = create(:contact, account: channel.account, phone_number: nil)
    target = create(:contact, account: channel.account, phone_number: '+77000000009')
    source_inbox = create(:contact_inbox, inbox: channel.inbox, contact: source, source_id: '77000000005')
    conversation = create(:conversation, account: channel.account, inbox: channel.inbox, contact: source, contact_inbox: source_inbox)
    appointment = create(:scheduling_appointment, account: channel.account, contact: source, conversation: conversation)
    touch = create(:reminder, account: channel.account, remindable: appointment, conversation: conversation,
                              body: 'Pending visit reminder', scheduled_at: 1.day.from_now)
    service = described_class.new(channel: channel, contact_payload: { remoteJid: '77000000009@s.whatsapp.net', pushName: 'Duplicate' })

    ActiveRecord::Base.transaction { service.send(:merge_contact_records!, source_contact: source, target_contact: target) }

    expect(Contact.exists?(source.id)).to be(false)
    expect(appointment.reload).to have_attributes(contact_id: target.id, conversation_id: conversation.id)
    expect(touch.reload).to have_attributes(target_contact_id: target.id, conversation_id: conversation.id)
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

  it 'moves communication threads when merging a provisional lid contact into an existing phone contact' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    phone_contact = create(
      :contact,
      account: channel.account,
      name: '+15559876543',
      phone_number: '+15559876543',
      identifier: nil,
      additional_attributes: { provider: 'whatsapp_web' }
    )
    create(:contact_inbox, inbox: channel.inbox, contact: phone_contact, source_id: '15559876543')

    provisional_contact = create(
      :contact,
      account: channel.account,
      name: 'LID User',
      identifier: 'whatsapp_web:143907392331785@lid'
    )
    thread = create(:communication_thread, account: channel.account, contact: provisional_contact)

    contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '15559876543@s.whatsapp.net',
        remoteLid: '143907392331785@lid',
        pushName: 'Alice'
      }
    ).perform

    expect(contact_inbox.contact_id).to eq(phone_contact.id)
    expect(thread.reload.contact_id).to eq(phone_contact.id)
    expect(Contact.exists?(provisional_contact.id)).to be false
  end

  it 'retries fresh failed provisional lid messages when the canonical phone jid arrives later' do
    allow(Avatar::AvatarFromUrlJob).to receive(:perform_later)

    provisional_contact_inbox = described_class.new(
      channel: channel,
      contact_payload: {
        remoteJid: '143907392331785@lid',
        pushName: 'Alice'
      }
    ).perform

    conversation = create(
      :conversation,
      account: channel.account,
      inbox: channel.inbox,
      contact: provisional_contact_inbox.contact,
      contact_inbox: provisional_contact_inbox
    )
    failed_message = create(
      :message,
      account: channel.account,
      inbox: channel.inbox,
      conversation: conversation,
      message_type: :outgoing,
      status: :failed,
      content_attributes: {
        external_error: "WhatsApp Web recipient is still a provisional @lid identity for conversation #{conversation.id}"
      }
    )

    clear_enqueued_jobs

    expect do
      described_class.new(
        channel: channel,
        contact_payload: {
          remoteJid: '15551234567@s.whatsapp.net',
          remoteLid: '143907392331785@lid',
          pushName: 'Alice'
        }
      ).perform
    end.to have_enqueued_job(SendReplyJob).with(failed_message.id).on_queue('outbound_messages')

    expect(failed_message.reload.status).to eq('sent')
    expect(failed_message.external_error).to be_nil
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
    original_reminder_fingerprint = (reminder = create_reminder_for_contact_inbox(provisional_contact_inbox)).fingerprint

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
    expect_reminder_reassigned(reminder, shared_contact, original_reminder_fingerprint, contact_inbox: resolved_contact_inbox)
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
