require 'rails_helper'

# M3 routing for a separate patient card with a доп. номер (owner decision 2026-09-29), evaluated at send time.
RSpec.describe Reminders::PatientSubjectGuard do
  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-api-key',
                      'FRONTEND_URL' => 'https://app.example.com') { example.run }
  end

  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }
  let(:shared) { Contacts::SharedPhone }
  let(:family_phone) { '+77000000009' }
  let(:web_inbox) { create(:channel_whatsapp_web, account: account).inbox }
  let(:owner) { create(:contact, account: account, name: 'Mother', phone_number: nil, identifier: 'whatsapp_web:55555@lid') }
  let(:owner_contact_inbox) { create(:contact_inbox, contact: owner, inbox: web_inbox, source_id: '55555@lid') }
  let(:conversation) { create(:conversation, account: account, inbox: web_inbox, contact: owner, contact_inbox: owner_contact_inbox) }

  def card_with_share(owner_id:, via: 'booking_chat', conversation_id: nil)
    create(:contact, account: account, name: 'Child', custom_attributes: {
             shared::CARD_KEY => true, 'secondary_phones' => [family_phone], shared::SHARED_PHONE_KEY => family_phone,
             shared::SHARED_OWNER_KEY => owner_id, shared::SHARED_VIA_KEY => via, shared::SHARED_CONVERSATION_KEY => conversation_id
           })
  end

  def appointment_for(card, contact: owner, chat: conversation)
    create(:scheduling_appointment, account: account, contact: contact, conversation: chat, patient_contact: card)
  end

  def route(appointment, inbox: nil) = described_class.notification_route(appointment.reload, inbox: inbox)

  it 'hidden-number share: notifications go through the booking chat', :aggregate_failures do
    appointment = appointment_for(card_with_share(owner_id: owner.id, conversation_id: conversation.id))

    expect(route(appointment)).to have_attributes(contact: owner, conversation: conversation, kind: :booking_chat)
    expect(described_class.notification_contact(appointment)).to eq(owner)
  end

  it 'once the booking chat reveals the number its contact is the holder, on the same chat' do
    appointment = appointment_for(card_with_share(owner_id: owner.id, conversation_id: conversation.id))
    owner.update!(phone_number: family_phone)

    expect(route(appointment)).to have_attributes(contact: owner, conversation: conversation, kind: :holder)
  end

  it 'uses the chat of another holder that chats from the number in the touch inbox', :aggregate_failures do
    card = card_with_share(owner_id: owner.id, conversation_id: conversation.id)
    appointment = appointment_for(card)
    holder = create(:contact, account: account, name: 'Mother WA', phone_number: family_phone)
    holder_contact_inbox = create(:contact_inbox, contact: holder, inbox: web_inbox, source_id: family_phone.delete('+'))
    holder_conversation = create(:conversation, account: account, inbox: web_inbox, contact: holder, contact_inbox: holder_contact_inbox)

    expect(route(appointment)).to have_attributes(contact: holder, conversation: holder_conversation, kind: :holder)
  end

  it 'never opens a new chat to the family number for a holder without a chat on it: the booking chat stays', :aggregate_failures do
    appointment = appointment_for(card_with_share(owner_id: owner.id, conversation_id: conversation.id))
    create(:contact, account: account, name: 'Sister', phone_number: family_phone)

    expect(route(appointment)).to have_attributes(contact: owner, conversation: conversation, kind: :booking_chat)
  end

  it 'keeps the booking chat when the holder chats from the number only in another inbox' do
    appointment = appointment_for(card_with_share(owner_id: owner.id, conversation_id: conversation.id))
    holder = create(:contact, account: account, name: 'Mother WA', phone_number: family_phone)
    other_inbox = create(:channel_whatsapp_web, account: account).inbox
    create(:contact_inbox, contact: holder, inbox: other_inbox, source_id: family_phone.delete('+'))

    expect(route(appointment)).to have_attributes(contact: owner, kind: :booking_chat)
    expect(route(appointment, inbox: other_inbox)).to have_attributes(contact: holder, kind: :holder)
  end

  context 'with a booking chat in an API inbox (no phone identities)' do
    let(:api_inbox) { create(:channel_api, account: account, webhook_url: nil).inbox }
    let(:mother) { create(:contact, account: account, name: 'Mother', phone_number: '+77000000008') }
    let(:mother_chat) { create(:contact_inbox, contact: mother, inbox: api_inbox, source_id: SecureRandom.uuid) }
    let(:booking) { create(:conversation, account: account, inbox: api_inbox, contact: mother, contact_inbox: mother_chat) }
    let(:dad) { create(:contact, account: account, name: 'Dad', phone_number: nil) }
    let(:dad_booking) do
      dad_chat = create(:contact_inbox, contact: dad, inbox: api_inbox, source_id: SecureRandom.uuid)
      create(:conversation, account: account, inbox: api_inbox, contact: dad, contact_inbox: dad_chat)
    end

    it 'H2 never routes to a holder that is neither the share owner nor tied to the number: the booking chat stays', :aggregate_failures do
      appointment = appointment_for(card_with_share(owner_id: mother.id, via: 'owner_primary'), contact: mother, chat: booking)
      stranger = create(:contact, account: account, name: 'Stranger', phone_number: family_phone)
      create(:contact_inbox, contact: stranger, inbox: api_inbox, source_id: family_phone.delete('+'))

      expect(route(appointment)).to have_attributes(contact: mother, conversation: booking, kind: :booking_chat)
      expect(route(appointment, inbox: api_inbox).contact).not_to eq(stranger)
    end

    it 'H2b keeps the booking chat for a share owner whose chats in that inbox are not the recorded booking chat', :aggregate_failures do
      booking
      appointment = appointment_for(card_with_share(owner_id: mother.id, via: 'owner_primary'), contact: dad, chat: dad_booking)
      mother.update!(phone_number: family_phone)
      # A later chat attached to the mother without proving the number (a widget visitor merged by phone, a public API
      # create by phone) and her own old chats are never "the holder's chat" in a channel without phone identities.
      create(:conversation, account: account, inbox: api_inbox, contact: mother, contact_inbox: mother_chat)

      expect(route(appointment)).to have_attributes(contact: dad, conversation: dad_booking, kind: :booking_chat)
      expect(route(appointment, inbox: api_inbox)).to have_attributes(contact: dad, conversation: dad_booking, kind: :booking_chat)
    end

    it 'H2b routes to the share owner only through the booking chat recorded with the share', :aggregate_failures do
      card = card_with_share(owner_id: mother.id, via: 'owner_primary', conversation_id: booking.id)
      appointment = appointment_for(card, contact: dad, chat: dad_booking)
      mother.update!(phone_number: family_phone)
      create(:conversation, account: account, inbox: api_inbox, contact: mother, contact_inbox: mother_chat)

      expect(route(appointment)).to have_attributes(contact: mother, conversation: booking, kind: :holder)
      other_api_inbox = create(:channel_api, account: account, webhook_url: nil).inbox
      expect(route(appointment, inbox: other_api_inbox)).to have_attributes(contact: dad, conversation: dad_booking, kind: :booking_chat)
    end
  end

  # sc8rv1 round 3 H2c (owner decision 2026-09-30): an appointment without a booking chat (MedElement import, booking
  # from a contact page) reaches a доп. номер only through the holder's own phone chat on it; otherwise nothing is sent.
  describe 'an appointment without a booking chat' do
    let(:widget_inbox) { create(:channel_widget, account: account).inbox }
    let(:cloud_inbox) { shared_phone_cloud_inbox(account) }

    def chatless(card, contact: owner) = appointment_for(card, contact: contact, chat: nil)

    it 'H2c-import fails closed for a hidden-number share, even with a recorded booking chat or a newer chat of the owner', :aggregate_failures do
      card = card_with_share(owner_id: owner.id, conversation_id: conversation.id)
      appointment = chatless(card, contact: Integrations::Medelement::PatientContactBinding.delivery_contact(card))
      widget_chat = create(:contact_inbox, contact: owner, inbox: widget_inbox)
      create(:conversation, account: account, inbox: widget_inbox, contact: owner, contact_inbox: widget_chat)

      expect(appointment.contact_id).to eq(owner.id)
      expect(route(appointment)).to have_attributes(contact: nil, conversation: nil, kind: :unroutable)
      expect(route(appointment, inbox: widget_inbox)).to be_unroutable
      expect(route(appointment, inbox: web_inbox)).to be_unroutable
    end

    it 'H2c-holder uses the holder chat whose channel identity is the number, never a widget or API chat of the holder', :aggregate_failures do
      owner.update!(phone_number: family_phone)
      number_ci = create(:contact_inbox, contact: owner, inbox: web_inbox, source_id: family_phone.delete('+'))
      number_chat = create(:conversation, account: account, inbox: web_inbox, contact: owner, contact_inbox: number_ci)
      widget_ci = create(:contact_inbox, contact: owner, inbox: widget_inbox)
      create(:conversation, account: account, inbox: widget_inbox, contact: owner, contact_inbox: widget_ci)
      dad = create(:contact, account: account, name: 'Dad', phone_number: '+77000000031')
      appointment = chatless(card_with_share(owner_id: owner.id, via: 'owner_primary'), contact: dad)

      expect(route(appointment)).to have_attributes(contact: owner, conversation: number_chat, kind: :holder)
      expect(route(appointment, inbox: web_inbox)).to have_attributes(contact: owner, conversation: number_chat, kind: :holder)
      expect(route(appointment, inbox: widget_inbox)).to be_unroutable
      # A phone inbox without a chat yet: a new chat on the number itself (the channel verifies the recipient).
      expect(route(appointment, inbox: cloud_inbox)).to have_attributes(contact: owner, conversation: nil, kind: :holder)
    end

    it 'H2c fails closed for a holder that has no chat on the number', :aggregate_failures do
      owner.update!(phone_number: family_phone)
      widget_ci = create(:contact_inbox, contact: owner, inbox: widget_inbox)
      create(:conversation, account: account, inbox: widget_inbox, contact: owner, contact_inbox: widget_ci)
      appointment = chatless(card_with_share(owner_id: owner.id, via: 'owner_primary'))

      expect(route(appointment)).to be_unroutable
      expect(route(appointment, inbox: widget_inbox)).to be_unroutable
    end
  end

  it 'falls back to the appointment contact once the доп. номер is removed from the card' do
    card = card_with_share(owner_id: owner.id, conversation_id: conversation.id)
    appointment = appointment_for(card)
    card.update!(custom_attributes: card.custom_attributes.merge('secondary_phones' => []))

    expect(route(appointment)).to have_attributes(contact: owner, kind: :appointment_contact)
  end

  it 'gives priority to the card own number' do
    card = card_with_share(owner_id: owner.id, conversation_id: conversation.id)
    appointment = appointment_for(card)
    card.update!(phone_number: '+77000000002')

    expect(route(appointment)).to have_attributes(contact: card, conversation: nil, kind: :own)
  end
end
