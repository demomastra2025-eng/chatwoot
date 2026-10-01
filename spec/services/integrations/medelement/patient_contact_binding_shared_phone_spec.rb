require 'rails_helper'

# Owner model 2026-09-29 (M1/M2): the family booking number never becomes the separate card's own primary when another
# contact holds it, chats from it, has it reserved, or when the booking chat did not show its phone.
RSpec.describe Integrations::Medelement::PatientContactBinding do
  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-api-key',
                      'FRONTEND_URL' => 'https://app.example.com') { example.run }
  end

  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }).tap { |record| record.enable_features!('scheduling') } }
  let(:policy) { Integrations::Medelement::AppointmentPatientIdentity }
  let(:shared) { Contacts::SharedPhone }
  let(:family_phone) { '+77000000009' }

  def owned_appointment(owner, conversation, phone: family_phone, identifier: nil)
    create(:scheduling_appointment, account: account, contact: owner, conversation: conversation,
                                    client_first_name: 'Child', client_last_name: 'Patient', client_middle_name: nil,
                                    client_name: 'Child Patient', client_phone: phone, client_identifier: identifier,
                                    custom_attributes: { policy::OWNED_IDENTITY_KEY => true, policy::EXPLICIT_IDENTIFIER_KEY => true })
  end

  def bind!(appointment, code: nil, allow_rebind: false, identifier: nil)
    appointment.with_lock do
      appointment.client_identifier = identifier if identifier
      described_class.new(appointment: appointment).prepare!(patient_code: code, allow_rebind: allow_rebind)
      appointment.save!
    end
    appointment.reload.patient_contact
  end

  def lid_owner
    inbox = create(:channel_whatsapp_web, account: account).inbox
    owner = create(:contact, account: account, name: 'Mother', phone_number: nil, identifier: 'whatsapp_web:55555@lid')
    contact_inbox = create(:contact_inbox, contact: owner, inbox: inbox, source_id: '55555@lid')
    [owner, create(:conversation, account: account, inbox: inbox, contact: owner, contact_inbox: contact_inbox)]
  end

  def telegram_owner
    channel = create(:channel_telegram_personal, account: account, phone_number: '+77000000555')
    owner = create(:contact, account: account, name: 'Mother', phone_number: nil, identifier: 'telegram_personal:55555')
    contact_inbox = create(:contact_inbox, contact: owner, inbox: channel.inbox, source_id: '55555')
    [owner, create(:conversation, account: account, inbox: channel.inbox, contact: owner, contact_inbox: contact_inbox)]
  end

  def expect_booking_chat_share(card, owner, conversation)
    expect(card.phone_number).to be_nil
    expect(card.custom_attributes).to include('secondary_phones' => [family_phone], shared::SHARED_PHONE_KEY => family_phone,
                                              shared::SHARED_OWNER_KEY => owner.id, shared::SHARED_VIA_KEY => 'booking_chat',
                                              shared::SHARED_CONVERSATION_KEY => conversation.id, shared::CARD_KEY => true)
  end

  it 'F2 WhatsApp Web LID-only chat: the booking number is only the card доп. номер shared from the booking chat', :aggregate_failures do
    owner, conversation = lid_owner
    card = bind!(owned_appointment(owner, conversation), code: 'child-2')

    expect_booking_chat_share(card, owner, conversation)
    expect(owner.reload.phone_number).to be_nil
    expect(shared.assignable_primary?(account_id: account.id, phone: family_phone, contact_id: owner.id)).to be(true)
  end

  it 'F2 Telegram Personal chat without a phone: the booking number is only the card доп. номер', :aggregate_failures do
    owner, conversation = telegram_owner
    card = bind!(owned_appointment(owner, conversation), code: 'child-2')

    expect_booking_chat_share(card, owner, conversation)
  end

  it 'F2 a hidden chat books a number another contact already holds: that contact owns the share' do
    owner, conversation = lid_owner
    holder = create(:contact, account: account, name: 'Father', phone_number: family_phone)
    card = bind!(owned_appointment(owner, conversation), code: 'child-2')

    expect(card.phone_number).to be_nil
    expect(card.custom_attributes).to include(shared::SHARED_OWNER_KEY => holder.id, shared::SHARED_VIA_KEY => 'owner_primary')
    expect(card.custom_attributes).not_to have_key(shared::SHARED_CONVERSATION_KEY)
  end

  it 'F1 visible phone: the chat contact owns the share and the booking chat is recorded' do
    owner = create(:contact, account: account, name: 'Mother', phone_number: family_phone)
    conversation = create(:conversation, account: account, contact: owner)
    card = bind!(owned_appointment(owner, conversation), code: 'child-2')

    expect(card.custom_attributes).to include(shared::SHARED_OWNER_KEY => owner.id, shared::SHARED_VIA_KEY => 'owner_primary',
                                              shared::SHARED_CONVERSATION_KEY => conversation.id)
  end

  it 'F1 a different free number becomes the card own primary when the booking chat shows its phone' do
    owner = create(:contact, account: account, name: 'Mother', phone_number: '+77000000001')
    card = bind!(owned_appointment(owner, create(:conversation, account: account, contact: owner), phone: family_phone), code: 'child-2')

    expect(card.phone_number).to eq(family_phone)
    expect(card.custom_attributes).not_to have_key(shared::SHARED_OWNER_KEY)
  end

  it 'keeps a hidden share reserved: a sibling booked with the same number from a visible chat gets it only as доп.', :aggregate_failures do
    owner, conversation = lid_owner
    first = bind!(owned_appointment(owner, conversation), code: 'child-2')
    aunt = create(:contact, account: account, name: 'Aunt', phone_number: '+77000000001')
    sibling = bind!(owned_appointment(aunt, create(:conversation, account: account, contact: aunt)), code: 'child-3')

    expect(sibling.phone_number).to be_nil
    expect(sibling.custom_attributes).to include(shared::SHARED_OWNER_KEY => owner.id, shared::SHARED_VIA_KEY => 'booking_chat',
                                                 shared::SHARED_CONVERSATION_KEY => conversation.id)
    expect(first.reload.phone_number).to be_nil
  end

  it 'F4 Q11 a draft corrected with an IIN keeps the old card without the number and never records it as owner', :aggregate_failures do
    owner, conversation = lid_owner
    appointment = owned_appointment(owner, conversation)
    first = bind!(appointment, allow_rebind: true)
    second = bind!(appointment.reload, allow_rebind: true, identifier: '940720300129')

    expect(second.id).not_to eq(first.id)
    expect(first.reload).to have_attributes(phone_number: nil)
    expect(first.custom_attributes['secondary_phones']).to be_blank
    expect(first.custom_attributes.keys & shared::SHARE_KEYS).to be_empty
    expect_booking_chat_share(second, owner, conversation)
  end

  it 'F4 a replaced draft that took a free booking number as primary releases it to the corrected card', :aggregate_failures do
    owner = create(:contact, account: account, name: 'Mother', phone_number: '+77000000001')
    appointment = owned_appointment(owner, create(:conversation, account: account, contact: owner))
    first = bind!(appointment, allow_rebind: true)
    expect(first.phone_number).to eq(family_phone)

    second = bind!(appointment.reload, allow_rebind: true, identifier: '940720300129')
    expect(first.reload.phone_number).to be_nil
    expect(second.phone_number).to eq(family_phone)
    expect(second.custom_attributes).not_to have_key(shared::SHARED_OWNER_KEY)
  end
end
