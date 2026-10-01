require 'rails_helper'

# Round-8 identity reproductions (Q5, Q5b, Q6c, Q9, Q10, Q11, Q11t) and the design-review import case, with the owner
# model 2026-09-29 expectations: the chat contact A is never merged into a patient card, keeps its conversation and
# message authorship, and takes the family number as primary when its own channel reveals it (M2, M7).
RSpec.describe Contacts::SharedPhone do
  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-api-key',
                      'FRONTEND_URL' => 'https://app.example.com') { example.run }
  end

  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }).tap { |record| record.enable_features!('scheduling') } }
  let(:policy) { Integrations::Medelement::AppointmentPatientIdentity }
  let(:family_phone) { '+77000000009' }
  let(:web_inbox) { create(:channel_whatsapp_web, account: account).inbox }
  let(:telegram) { create(:channel_telegram_personal, account: account, phone_number: '+77000000555') }

  def owned_appointment(owner, conversation)
    create(:scheduling_appointment, account: account, contact: owner, conversation: conversation,
                                    client_first_name: 'Child', client_last_name: 'Patient', client_middle_name: nil,
                                    client_name: 'Child Patient', client_phone: family_phone, client_identifier: nil,
                                    custom_attributes: { policy::OWNED_IDENTITY_KEY => true, policy::EXPLICIT_IDENTIFIER_KEY => true })
  end

  def bind!(appointment, code: nil, allow_rebind: false, identifier: nil)
    appointment.with_lock do
      appointment.client_identifier = identifier if identifier
      Integrations::Medelement::PatientContactBinding.new(appointment: appointment).prepare!(patient_code: code, allow_rebind: allow_rebind)
      appointment.save!
    end
    appointment.reload.patient_contact
  end

  def web_owner(inbox)
    owner = create(:contact, account: account, name: 'Mother', phone_number: nil, identifier: 'whatsapp_web:55555@lid')
    contact_inbox = create(:contact_inbox, contact: owner, inbox: inbox, source_id: '55555@lid')
    conversation = create(:conversation, account: account, inbox: inbox, contact: owner, contact_inbox: contact_inbox)
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: owner, message_type: :incoming)
    [owner, conversation]
  end

  def telegram_owner(channel, peer: '55555')
    owner = create(:contact, account: account, name: 'Mother', phone_number: nil, identifier: "telegram_personal:#{peer}")
    contact_inbox = create(:contact_inbox, contact: owner, inbox: channel.inbox, source_id: peer)
    conversation = create(:conversation, account: account, inbox: channel.inbox, contact: owner, contact_inbox: contact_inbox)
    create(:message, account: account, inbox: channel.inbox, conversation: conversation, sender: owner, message_type: :incoming)
    [owner, conversation]
  end

  def resolve_lid!(inbox, with_lid: true)
    payload = { remoteJid: '77000000009@s.whatsapp.net', pushName: 'Mother' }
    payload[:remoteLid] = '55555@lid' if with_lid
    WhatsappWeb::ContactSyncService.new(channel: inbox.channel, contact_payload: payload).perform
  end

  def reveal_telegram!(channel, peer: '55555')
    TelegramPersonal::ContactSyncService.new(inbox: channel.inbox, params: { peer_user_id: peer, chat_id: peer, first_name: 'Mother',
                                                                             phone_number: '77000000009', sync_source: 'saved_contact' }).perform
  end

  def expect_owner_intact(owner, conversation, phone: family_phone)
    expect(Contact.exists?(owner.id)).to be(true)
    expect(owner.reload.phone_number).to eq(phone)
    expect(conversation.reload.contact_id).to eq(owner.id)
    expect(conversation.messages.incoming.pluck(:sender_id).uniq).to eq([owner.id])
  end

  def expect_card_shares(card, owner)
    expect(card.reload.phone_number).to be_nil
    expect(card.custom_attributes).to include('secondary_phones' => [family_phone], described_class::SHARED_OWNER_KEY => owner.id)
  end

  context 'with the round-8 reproductions' do
    it 'Q5 WhatsApp Web LID-only owner: the LID resolves and the owner takes the family number', :aggregate_failures do
      owner, conversation = web_owner(web_inbox)
      card = bind!(owned_appointment(owner, conversation), code: 'child-2')
      resolve_lid!(web_inbox)

      expect_owner_intact(owner, conversation)
      expect_card_shares(card, owner)
    end

    it 'Q5b WhatsApp Web phone JID without the LID link: a new chat contact holds the number, never the card', :aggregate_failures do
      owner, conversation = web_owner(web_inbox)
      card = bind!(owned_appointment(owner, conversation), code: 'child-2')
      contact_inbox = resolve_lid!(web_inbox, with_lid: false)

      expect(contact_inbox.contact_id).not_to eq(card.id)
      expect(contact_inbox.contact.phone_number).to eq(family_phone)
      expect_owner_intact(owner, conversation, phone: nil)
      expect_card_shares(card, owner)
    end

    it 'Q6c WhatsApp Cloud inbound from the family number is never filed under the card', :aggregate_failures do
      stub_request(:post, 'https://waba.360dialog.io/v1/configs/webhook')
      owner, conversation = telegram_owner(telegram)
      card = bind!(owned_appointment(owner, conversation), code: 'child-2')
      cloud = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
      params = {
        'contacts' => [{ 'profile' => { 'name' => 'Mother' }, 'wa_id' => '77000000009' }],
        'messages' => [{ 'from' => '77000000009', 'id' => 'wamid-v8-q6c', 'text' => { 'body' => 'Hello' },
                         'timestamp' => Time.current.to_i.to_s, 'type' => 'text' }]
      }.with_indifferent_access
      Whatsapp::IncomingMessageService.new(inbox: cloud.inbox, params: params).perform

      cloud_conversation = cloud.inbox.conversations.last
      expect(cloud_conversation.contact_id).not_to eq(card.id)
      expect(cloud_conversation.contact.phone_number).to eq(family_phone)
      expect_card_shares(card, owner)
      expect(conversation.reload.contact_id).to eq(owner.id)
    end

    it 'Q9 appointment deleted: the LID still resolves to the owner and nothing is merged' do
      owner, conversation = web_owner(web_inbox)
      appointment = owned_appointment(owner, conversation)
      card = bind!(appointment, code: 'child-2')
      appointment.destroy!
      resolve_lid!(web_inbox)

      expect_owner_intact(owner, conversation)
      expect(Contact.exists?(card.id)).to be(true)
    end

    it 'Q10 a second phone-less family contact learns the number and becomes its first holder', :aggregate_failures do
      owner, conversation = web_owner(web_inbox)
      card = bind!(owned_appointment(owner, conversation), code: 'child-2')
      other, other_conversation = telegram_owner(telegram, peer: '77777')
      reveal_telegram!(telegram, peer: '77777')

      expect_owner_intact(other, other_conversation)
      expect_owner_intact(owner, conversation, phone: nil)
      expect_card_shares(card, owner)
    end

    it 'Q11 draft booked without IIN, IIN added later, then the LID resolves', :aggregate_failures do
      owner, conversation = web_owner(web_inbox)
      appointment = owned_appointment(owner, conversation)
      first = bind!(appointment, allow_rebind: true)
      second = bind!(appointment.reload, allow_rebind: true, identifier: '940720300129')
      resolve_lid!(web_inbox)

      expect_owner_intact(owner, conversation)
      expect(first.reload.phone_number).to be_nil
      expect_card_shares(second, owner)
      expect(appointment.reload).to have_attributes(contact_id: owner.id, patient_contact_id: second.id)
    end

    it 'Q11t Telegram variant: IIN added later, then the saved contact reveals the number', :aggregate_failures do
      owner, conversation = telegram_owner(telegram)
      appointment = owned_appointment(owner, conversation)
      bind!(appointment, allow_rebind: true)
      second = bind!(appointment.reload, allow_rebind: true, identifier: '940720300129')
      reveal_telegram!(telegram)

      expect_owner_intact(owner, conversation)
      expect_card_shares(second, owner)
    end
  end

  context 'with a MedElement import that holds its own free family number (design review)' do
    it 'never absorbs the WhatsApp Web LID chat that later reveals the number', :aggregate_failures do
      owner, conversation = web_owner(web_inbox)
      imported = create(:contact, account: account, name: 'Son', phone_number: family_phone,
                                  custom_attributes: { 'medelement_patient_code' => 'son-1' })
      resolve_lid!(web_inbox)

      expect_owner_intact(owner, conversation, phone: nil)
      expect(imported.reload).to have_attributes(phone_number: family_phone)
      expect(imported.contact_inboxes).to be_empty
      expect(Message.where(sender_type: 'Contact', sender_id: imported.id)).to be_empty
    end

    it 'keeps it separate from the Telegram chat that reveals the number', :aggregate_failures do
      owner, conversation = telegram_owner(telegram)
      imported = create(:contact, account: account, name: 'Son', phone_number: family_phone,
                                  custom_attributes: { 'medelement_patient_code' => 'son-1' })
      reveal_telegram!(telegram)

      expect_owner_intact(owner, conversation, phone: nil)
      expect(imported.reload.contact_inboxes).to be_empty
    end
  end
end
