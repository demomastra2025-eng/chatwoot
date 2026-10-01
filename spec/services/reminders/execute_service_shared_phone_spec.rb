require 'rails_helper'

# M3 at send time for family numbers, M8 wakeup route re-check, and the no-steal ContactInbox rule for every route of a
# separate patient's appointment (design review: holder routes never rename another contact's chat identity).
RSpec.describe Reminders::ExecuteService do
  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-api-key',
                      'FRONTEND_URL' => 'https://app.example.com') { example.run }
  end

  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }).tap { |record| record.enable_features!('scheduling') } }
  let(:policy) { Integrations::Medelement::AppointmentPatientIdentity }
  let(:family_phone) { '+77000000009' }

  def touch_messages(touch)
    Message.outgoing.where(account_id: account.id).where("additional_attributes ->> 'touch_id' = ?", touch.id.to_s)
  end

  def owned_appointment(owner, conversation)
    create(:scheduling_appointment, account: account, contact: owner, conversation: conversation,
                                    client_first_name: 'Child', client_last_name: 'Patient', client_middle_name: nil,
                                    client_name: 'Child Patient', client_phone: family_phone, client_identifier: nil,
                                    starts_at: 2.days.from_now, ends_at: 2.days.from_now + 30.minutes,
                                    custom_attributes: { policy::OWNED_IDENTITY_KEY => true, policy::EXPLICIT_IDENTIFIER_KEY => true })
  end

  def bind!(appointment)
    appointment.with_lock do
      Integrations::Medelement::PatientContactBinding.new(appointment: appointment).prepare!(patient_code: 'child-2')
      appointment.save!
    end
    appointment.reload.patient_contact
  end

  def processing_touch(appointment, conversation, **attributes)
    create(:reminder, account: account, touch_conversation: conversation, conversation: conversation, remindable: appointment,
                      status: :processing, body: 'Visit reminder', scheduled_at: 1.minute.ago, **attributes)
  end

  context 'with a Telegram Personal booking chat that did not show its phone' do
    let(:channel) { create(:channel_telegram_personal, account: account, phone_number: '+77000000555') }
    let(:owner) { create(:contact, account: account, name: 'Mother', phone_number: nil, identifier: 'telegram_personal:55555') }
    let(:owner_contact_inbox) { create(:contact_inbox, contact: owner, inbox: channel.inbox, source_id: '55555') }
    let(:conversation) { create(:conversation, account: account, inbox: channel.inbox, contact: owner, contact_inbox: owner_contact_inbox) }

    it 'Q6r delivers the card reminder in the booking chat before and after the chat reveals the number', :aggregate_failures do
      appointment = owned_appointment(owner, conversation)
      card = bind!(appointment)
      first = processing_touch(appointment, conversation)
      described_class.new(reminder: first).perform

      TelegramPersonal::ContactSyncService.new(inbox: channel.inbox, params: { peer_user_id: '55555', chat_id: '55555', first_name: 'Mother',
                                                                               phone_number: '77000000009', sync_source: 'saved_contact' }).perform
      second = processing_touch(appointment.reload, conversation)
      described_class.new(reminder: second).perform

      expect(owner.reload.phone_number).to eq(family_phone)
      [first, second].each do |touch|
        expect(touch.reload).to have_attributes(status: 'completed', target_contact_id: owner.id)
        expect(touch_messages(touch).sole.conversation_id).to eq(conversation.id)
      end
      expect(card.reload.phone_number).to be_nil
      expect(Conversation.where(contact_id: card.id)).to be_empty
    end
  end

  context 'with a WhatsApp Web LID-only booking chat' do
    let(:inbox) { create(:channel_whatsapp_web, account: account).inbox }
    let(:owner) { create(:contact, account: account, name: 'Mother', phone_number: nil, identifier: 'whatsapp_web:55555@lid') }
    let(:owner_contact_inbox) { create(:contact_inbox, contact: owner, inbox: inbox, source_id: '55555@lid') }
    let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: owner, contact_inbox: owner_contact_inbox) }

    it 'sends in the LID chat and never opens a second chat to the family number', :aggregate_failures do
      appointment = owned_appointment(owner, conversation)
      card = bind!(appointment)
      touch = processing_touch(appointment, conversation)

      described_class.new(reminder: touch).perform

      expect(touch.reload).to have_attributes(status: 'completed', target_contact_id: owner.id, target_conversation_id: conversation.id)
      expect(touch_messages(touch).sole.conversation_id).to eq(conversation.id)
      expect(ContactInbox.where(inbox: inbox, source_id: family_phone.delete('+'))).to be_empty
      expect(card.reload.contact_inboxes).to be_empty
    end

    it 'M8 re-queues a wakeup whose route changes during generation and then runs it once on the current route', :aggregate_failures do
      appointment = owned_appointment(owner, conversation)
      card = bind!(appointment)
      create(:contact_inbox, contact: card, inbox: inbox, source_id: '77000000002')
      assistant = create(:captain_assistant, account: account)
      touch = processing_touch(appointment, conversation, action_type: :ai_agent_wakeup, metadata: { 'captain_assistant_id' => assistant.id })
      calls = 0
      allow_any_instance_of(Reminders::CaptainGeneratedMessageService).to receive(:perform) do # rubocop:disable RSpec/AnyInstance
        calls += 1
        card.update_columns(phone_number: '+77000000002') if calls == 1 # rubocop:disable Rails/SkipsModelValidations
        { content: 'Captain wakeup message', assistant: assistant, captain_trace: {} }
      end

      described_class.new(reminder: touch).perform
      expect(touch.reload).to have_attributes(status: 'pending', last_error: nil, target_contact_id: card.id)
      expect(touch_messages(touch)).to be_empty

      described_class.new(reminder: touch, processing_claim: touch.mark_processing!).perform

      expect(touch.reload).to be_completed
      expect(touch_messages(touch).map { |message| message.conversation.contact_id }).to eq([card.id])
      expect(conversation.messages.outgoing).to be_empty
    end
  end

  context 'with the previous holder own appointment booked in the chat of the number (sc8rv2 X1)' do
    let(:inbox) { create(:channel_whatsapp_web, account: account).inbox }
    let(:mother) { create(:contact, account: account, name: 'Mother', phone_number: '+77000000008') }

    # The promotion runs with the capabilities switched on (they ship off, see Contacts::SharedPhoneSwitches).
    before { enable_shared_phone_switches! }

    it 'X1 re-queues a touch whose resolved chat moved to the card before the send, then sends it to the holder own chat',
       :aggregate_failures do
      _contact_inbox, conversation = shared_phone_chat(account, mother, inbox, family_phone.delete('+'))
      card = shared_phone_card(account, mother)
      appointment = create(:scheduling_appointment, account: account, contact: mother, conversation: conversation,
                                                    client_first_name: 'Mother', client_last_name: 'Own', client_middle_name: nil,
                                                    client_name: 'Mother Own', client_phone: '+77000000008', client_identifier: nil,
                                                    starts_at: 2.days.from_now, ends_at: 2.days.from_now + 30.minutes)
      touch = processing_touch(appointment, conversation)
      promoted = false
      allow_any_instance_of(Reminders::ConversationResolver).to receive(:perform).and_wrap_original do |original, *args| # rubocop:disable RSpec/AnyInstance
        resolved = original.call(*args)
        # another worker: the MedElement promotion of the card commits between conversation resolution and the send
        Contacts::SharedPhonePromotionService.new(card: Contact.find(card.id), basis: 'medelement').perform unless promoted
        promoted = true
        resolved
      end

      described_class.new(reminder: touch).perform

      expect(conversation.reload.contact_id).to eq(card.id)
      expect(touch.reload).to have_attributes(status: 'pending', target_contact_id: mother.id)
      expect(touch.target_conversation_id).not_to eq(conversation.id)
      expect(touch_messages(touch)).to be_empty

      described_class.new(reminder: touch, processing_claim: touch.mark_processing!).perform

      expect(touch.reload).to be_completed
      delivered = touch_messages(touch).sole.conversation
      expect(delivered.contact_id).to eq(mother.id)
      expect(delivered.id).not_to eq(conversation.id)
    end
  end

  context 'with a previous holder that still chats from the number (design review)' do
    let(:cloud_inbox) do
      create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
    end
    let(:second_cloud_inbox) do
      create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
    end
    let(:owner) { create(:contact, account: account, name: 'Mother', phone_number: family_phone) }
    let!(:owner_contact_inbox) { create(:contact_inbox, contact: owner, inbox: cloud_inbox, source_id: family_phone.delete('+')) }
    let(:conversation) { create(:conversation, account: account, inbox: cloud_inbox, contact: owner, contact_inbox: owner_contact_inbox) }

    it 'never renames or takes over the previous holder chat identity for any route', :aggregate_failures do
      appointment = owned_appointment(owner, conversation)
      card = bind!(appointment)
      owner.update!(phone_number: '+77000000008')
      holder = create(:contact, account: account, name: 'Mother new', phone_number: family_phone)
      create(:contact_inbox, contact: holder, inbox: second_cloud_inbox, source_id: family_phone.delete('+'))
      create(:message, account: account, inbox: cloud_inbox, conversation: conversation, sender: owner, message_type: :incoming)
      touch = create(:reminder, account: account, conversation: conversation, remindable: appointment.reload, status: :pending,
                                target_inbox: cloud_inbox)

      # The holder does not chat from the number in the touch inbox: the route stays on the booking chat's contact.
      expect(Reminders::PatientSubjectGuard.notification_route(appointment.reload, inbox: cloud_inbox).contact).to eq(owner)

      # Even a touch pointed at the holder never renames the previous holder's ContactInbox to open its own.
      touch.update_columns(target_contact_id: holder.id, target_contact_inbox_id: nil, target_conversation_id: nil) # rubocop:disable Rails/SkipsModelValidations
      expect { Reminders::ConversationResolver.new(reminder: touch.reload).perform }
        .to raise_error(Reminders::UndeliverableTargetError, Reminders::ConversationResolver::PATIENT_NUMBER_TAKEN)

      expect(owner_contact_inbox.reload).to have_attributes(contact_id: owner.id, source_id: family_phone.delete('+'))
      expect(ContactInbox.where(inbox: cloud_inbox).where('source_id LIKE ?', 'whatsapp:%')).to be_empty
      expect(ContactInbox.where(inbox: cloud_inbox, contact_id: holder.id)).to be_empty
      expect(card.reload.contact_inboxes).to be_empty
    end
  end
end
