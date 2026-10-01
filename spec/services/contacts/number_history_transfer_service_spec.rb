require 'rails_helper'

# M6: the chat history of a number moves from its previous holder to the card only through this explicit transfer.
RSpec.describe Contacts::NumberHistoryTransferService do
  include ActiveJob::TestHelper

  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-api-key',
                      'FRONTEND_URL' => 'https://app.example.com') { example.run }
  end

  let(:account) { create(:account, locale: 'ru', limits: { non_web_inboxes: ChatwootApp.max_limit }) }
  let(:family_phone) { '+77000000009' }
  let(:digits) { '77000000009' }
  let(:mother) { create(:contact, account: account, name: 'Mother', phone_number: '+77000000008') }
  let(:son) do
    create(:contact, account: account, name: 'Son', phone_number: family_phone, custom_attributes: { 'medelement_patient_code' => 'son-1' })
  end
  let(:agent) { create(:user, account: account, name: 'Admin') }
  let(:cloud_inbox) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
  end
  let(:other_inbox) { create(:inbox, account: account) }

  # The transfer with history transfer switched on (it ships off, see Contacts::SharedPhoneSwitches).
  before { enable_shared_phone_switches! }

  def chat(contact, inbox, source_id)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: source_id)
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: contact, message_type: :incoming)
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: agent, message_type: :outgoing)
    [contact_inbox, conversation]
  end

  def transfer!(basis: 'administrator', actor: agent)
    described_class.new(account: account, phone: family_phone, from: mother, to: son, basis: basis, actor: actor, promoted: true).perform!
  end

  def revert(entry, **)
    Contacts::NumberHistoryTransferRevertService.new(contact: son, transfer_id: entry['id'], **).perform
  end

  it 'moves the chats of the number with their contact messages and leaves everything else', :aggregate_failures do
    number_ci, number_conversation = chat(mother, cloud_inbox, digits)
    other_ci, other_conversation = chat(mother, other_inbox, 'mother-widget')
    create(:csat_survey_response, account: account, conversation: number_conversation, contact: mother,
                                  message: number_conversation.messages.outgoing.first)
    note = create(:note, account: account, contact: mother)

    result = transfer!

    expect(result.created).to be(true)
    expect(number_ci.reload.contact_id).to eq(son.id)
    expect(number_conversation.reload.contact_id).to eq(son.id)
    expect(number_conversation.messages.incoming.pluck(:sender_id)).to eq([son.id])
    expect(number_conversation.messages.outgoing.pluck(:sender_type, :sender_id)).to eq([['User', agent.id]])
    expect(CsatSurveyResponse.find_by(conversation_id: number_conversation.id).contact_id).to eq(son.id)
    expect([other_ci.reload.contact_id, other_conversation.reload.contact_id, note.reload.contact_id]).to all(eq(mother.id))
    expect(other_conversation.messages.incoming.pluck(:sender_id)).to eq([mother.id])
    expect(mother.reload.phone_number).to eq('+77000000008')
  end

  it 'posts an activity message and records the transfer on both contacts', :aggregate_failures do
    number_ci, number_conversation = chat(mother, cloud_inbox, digits)
    entry = transfer!.entry

    activity = number_conversation.messages.activity.last
    expect(activity.content).to include('+7 *** ***-**-09', 'Mother', 'Son', 'администратор Admin')
    expect(activity.content).not_to include(family_phone)
    son_log = son.reload.custom_attributes[Contacts::SharedPhone::TRANSFERS_KEY].first
    mother_log = mother.reload.custom_attributes[Contacts::SharedPhone::TRANSFERS_KEY].first
    expect(son_log).to include('id' => entry['id'], 'direction' => 'in', 'counterpart_contact_id' => mother.id, 'basis' => 'administrator',
                               'contact_inbox_ids' => [number_ci.id], 'conversation_ids' => [number_conversation.id],
                               'moved_message_count' => 1, 'actor' => { 'type' => 'User', 'id' => agent.id }, 'promoted' => true)
    expect(mother_log).to include('id' => entry['id'], 'direction' => 'out', 'counterpart_contact_id' => son.id)
  end

  it 'writes the activity message in the account language' do
    account.update!(locale: 'en')
    _number_ci, number_conversation = chat(mother, cloud_inbox, digits)
    transfer!(basis: 'medelement', actor: nil)

    expect(number_conversation.messages.activity.last.content).to include('Chat history of +7 *** ***-**-09', 'MedElement (automatic)')
  end

  it 'is idempotent: a second run moves nothing and posts no second activity message', :aggregate_failures do
    _number_ci, number_conversation = chat(mother, cloud_inbox, digits)
    transfer!

    expect(transfer!.created).to be(false)
    expect(number_conversation.messages.activity.count).to eq(1)
    expect(son.reload.custom_attributes[Contacts::SharedPhone::TRANSFERS_KEY].size).to eq(1)
  end

  it 'keeps settled touches and open touches of the moved chat with the chat, and clears only the previous holder own ones',
     :aggregate_failures do
    number_ci, number_conversation = chat(mother, cloud_inbox, digits)
    create(:message, account: account, inbox: cloud_inbox, conversation: number_conversation, sender: mother, message_type: :incoming)
    settled = create(:reminder, account: account, conversation: number_conversation, remindable: number_conversation, status: :pending)
    settled.update_columns(status: Reminder.statuses[:completed]) # rubocop:disable Rails/SkipsModelValidations
    follow_up = create(:reminder, account: account, conversation: number_conversation, remindable: number_conversation, status: :pending)
    expect(follow_up.reload.target_contact_inbox_id).to eq(number_ci.id)
    own_visit = create(:scheduling_appointment, account: account, contact: mother, conversation: number_conversation,
                                                starts_at: 2.days.from_now, ends_at: 2.days.from_now + 30.minutes)
    own = create(:reminder, account: account, conversation: number_conversation, touch_conversation: number_conversation,
                            remindable: own_visit, status: :pending)
    expect(own.reload).to have_attributes(target_contact_id: mother.id, target_conversation_id: number_conversation.id)

    entry = transfer!.entry

    expect(settled.reload).to have_attributes(target_contact_id: son.id, target_conversation_id: number_conversation.id)
    expect(settled).to be_valid
    # sc8rv2 T3: an agent's follow-up scheduled in the moved chat follows it (M6: it is tied to the number's chat).
    expect(follow_up.reload).to have_attributes(target_contact_id: son.id, target_contact_inbox_id: number_ci.id,
                                                target_conversation_id: number_conversation.id)
    expect(follow_up).to be_valid
    # The previous holder's own appointment is not tied to the number: its touch re-resolves to her current route.
    expect(own.reload).to have_attributes(target_contact_id: mother.id, target_contact_inbox_id: nil, target_conversation_id: nil)
    expect(entry).to include('settled_reminder_ids' => [settled.id], 'followed_open_reminder_ids' => [follow_up.id],
                             'cleared_open_reminder_ids' => [own.id])
  end

  context 'with WhatsApp Web chats of the number' do
    let(:web_inbox) { create(:channel_whatsapp_web, account: account).inbox }

    before { mother.update!(identifier: 'whatsapp_web:55555@lid') }

    it 'moves a provably tied LID chat and its identifier with the phone-JID chat', :aggregate_failures do
      phone_ci, = chat(mother, web_inbox, digits)
      lid_ci, lid_conversation = chat(mother, web_inbox, '55555@lid')
      create(:contact_channel_profile, contact: mother, contact_inbox: phone_ci, profile_data: { 'lid_jid' => '55555@lid' })

      transfer!

      expect([phone_ci.reload.contact_id, lid_ci.reload.contact_id, lid_conversation.reload.contact_id]).to all(eq(son.id))
      expect(mother.reload.identifier).to be_nil
      expect(son.reload.identifier).to eq('whatsapp_web:55555@lid')
    end

    it 'leaves an unproven LID chat, then moves it when a resolved payload proves the tie', :aggregate_failures do
      phone_ci, = chat(mother, web_inbox, digits)
      lid_ci, lid_conversation = chat(mother, web_inbox, '55555@lid')
      entry = transfer!.entry
      expect(phone_ci.reload.contact_id).to eq(son.id)
      expect(lid_ci.reload.contact_id).to eq(mother.id)
      expect(mother.reload.identifier).to eq('whatsapp_web:55555@lid')

      WhatsappWeb::ContactSyncService.new(channel: web_inbox.channel, contact_payload: { remoteJid: "#{digits}@s.whatsapp.net",
                                                                                         remoteLid: '55555@lid', pushName: 'Mother' }).perform

      expect([lid_ci.reload.contact_id, lid_conversation.reload.contact_id]).to all(eq(son.id))
      expect(lid_conversation.messages.incoming.pluck(:sender_id)).to eq([son.id])
      expect(mother.reload.identifier).to be_nil
      amendment = son.reload.custom_attributes[Contacts::SharedPhone::TRANSFERS_KEY].first
      expect(amendment).to include('amendment_of' => entry['id'], 'contact_inbox_ids' => [lid_ci.id])
    end

    # sc8rv1 round 3 AMEND-a/b/k: a recorded transfer is no proof once the card released the number.
    def resolved_payload!
      WhatsappWeb::ContactSyncService.new(channel: web_inbox.channel, contact_payload: { remoteJid: "#{digits}@s.whatsapp.net",
                                                                                         remoteLid: '55555@lid', pushName: 'Mother' }).perform
    end

    def lid_chat_owners(lid_ci, lid_conversation)
      [lid_ci.reload.contact_id, lid_conversation.reload.contact_id, *lid_conversation.messages.incoming.pluck(:sender_id)].uniq
    end

    def expect_mother_keeps_lid_chat(lid_ci, lid_conversation)
      expect(lid_chat_owners(lid_ci, lid_conversation)).to eq([mother.id])
      expect(mother.reload.identifier).to eq('whatsapp_web:55555@lid')
      expect(Array(son.reload.custom_attributes[Contacts::SharedPhone::TRANSFERS_KEY]).pluck('amendment_of').compact).to be_empty
    end

    it 'AMEND-a never moves the LID chat of the mother once staff gave the number back to her', :aggregate_failures do
      chat(mother, web_inbox, digits)
      lid_ci, lid_conversation = chat(mother, web_inbox, '55555@lid')
      transfer!
      son.update!(phone_number: '+77000000061')
      mother.update!(phone_number: family_phone)

      expect(resolved_payload!).to be_present
      expect_mother_keeps_lid_chat(lid_ci, lid_conversation)
    end

    it 'AMEND-b never moves the LID chat while nobody holds the number as primary', :aggregate_failures do
      chat(mother, web_inbox, digits)
      lid_ci, lid_conversation = chat(mother, web_inbox, '55555@lid')
      transfer!
      son.update!(phone_number: '+77000000061')

      expect(resolved_payload!).to be_present
      expect_mother_keeps_lid_chat(lid_ci, lid_conversation)
    end

    it 'AMEND-k never moves the LID chat while history transfer is switched off', :aggregate_failures do
      phone_ci, = chat(mother, web_inbox, digits)
      lid_ci, lid_conversation = chat(mother, web_inbox, '55555@lid')
      transfer!
      disable_shared_phone_switches!(Contacts::SharedPhoneSwitches::HISTORY_TRANSFER)

      expect(resolved_payload!).to eq(phone_ci)
      expect(described_class.amend_tied_lid!(contact_inbox: phone_ci.reload, lid_source_id: '55555@lid')).to be_nil
      expect_mother_keeps_lid_chat(lid_ci, lid_conversation)
    end

    # sc8rv2 round 3 RVL2: a proven LID chat moved to the card (M7x) stays there after the transfer is reverted; the
    # revert entry on the mother is not an amendable transfer, so her next resolved payload is processed, not raised.
    it 'RVL2 still processes the mother payload after a revert (a revert entry is not an amendable transfer)', :aggregate_failures do
      phone_ci, = chat(mother, web_inbox, digits)
      lid_contact = create(:contact, account: account, name: 'Mother LID', identifier: 'whatsapp_web:66666@lid')
      lid_ci, = chat(lid_contact, web_inbox, '66666@lid')
      payload = { remoteJid: "#{digits}@s.whatsapp.net", remoteLid: '66666@lid', pushName: 'Mother' }
      entry = transfer!.entry
      WhatsappWeb::ContactSyncService.new(channel: web_inbox.channel, contact_payload: payload).perform
      expect(lid_ci.reload.contact_id).to eq(son.id)
      revert(entry, dry_run: false)

      expect { WhatsappWeb::ContactSyncService.new(channel: web_inbox.channel, contact_payload: payload).perform }.not_to raise_error
      expect(phone_ci.reload.contact_id).to eq(mother.id)
      expect(lid_ci.reload.contact_id).to eq(son.id)
    end
  end

  describe 'with history transfer switched off (the shipped default)' do
    before { disable_shared_phone_switches! }

    it 'refuses the transfer before touching anything and schedules no sweep', :aggregate_failures do
      number_ci, number_conversation = chat(mother, cloud_inbox, digits)

      expect { expect { transfer! }.to raise_error(described_class::Disabled) }.not_to have_enqueued_job(Contacts::NumberHistoryTransferSweepJob)
      expect(number_ci.reload.contact_id).to eq(mother.id)
      expect(number_conversation.reload.contact_id).to eq(mother.id)
      expect(number_conversation.messages.incoming.pluck(:sender_id)).to eq([mother.id])
      expect(number_conversation.messages.activity.count).to eq(0)
      expect([son.reload, mother.reload].map { |contact| contact.custom_attributes.key?(Contacts::SharedPhone::TRANSFERS_KEY) }).to eq([false, false])
    end

    it 'keeps a transfer recorded while it was on as it is: no sweep, no amendment, no applied revert', :aggregate_failures do
      enable_shared_phone_switches!
      number_ci, number_conversation = chat(mother, cloud_inbox, digits)
      entry = transfer!.entry
      late_message = create(:message, account: account, inbox: cloud_inbox, conversation: number_conversation, sender: mother,
                                      message_type: :incoming)
      disable_shared_phone_switches!

      Contacts::NumberHistoryTransferSweepJob.perform_now(account.id, son.id, entry['id'])
      expect(late_message.reload.sender_id).to eq(mother.id)
      expect(revert(entry).dry_run).to be(true)
      expect { revert(entry, dry_run: false) }.to raise_error(described_class::Disabled)
      expect(number_ci.reload.contact_id).to eq(son.id)
      expect(described_class.find_entry(son.reload, entry['id'])['reverted_at']).to be_nil
    end
  end

  it 'keeps a Telegram chat whose payload never carried the number with the previous holder' do
    channel = create(:channel_telegram_personal, account: account, phone_number: '+77000000555')
    peer, = chat(mother, channel.inbox, '777001')
    create(:contact_channel_profile, contact: mother, contact_inbox: peer, phone_number: family_phone, profile_data: {})
    chat(mother, cloud_inbox, digits)

    transfer!

    expect(peer.reload.contact_id).to eq(mother.id)
  end

  it 'T1 keeps a Telegram chat whose profile phone was only copied from the contact, and moves one proven by the peer payload',
     :aggregate_failures do
    channel = create(:channel_telegram_personal, account: account, phone_number: '+77000000555')
    mother.update!(phone_number: family_phone)
    copied_ci = ContactInboxBuilder.new(contact: mother, inbox: channel.inbox, source_id: '55501').perform
    copied_conversation = create(:conversation, account: account, inbox: channel.inbox, contact: mother, contact_inbox: copied_ci)
    peer_payload = { peer_user_id: '55502', chat_id: '55502', first_name: 'Mother', phone_number: digits, sync_source: 'saved_contact' }
    TelegramPersonal::ContactSyncService.new(inbox: channel.inbox, params: peer_payload).perform
    proven_ci = channel.inbox.contact_inboxes.find_by(source_id: '55502')
    mother.update!(phone_number: '+77000000008')
    chat(mother, cloud_inbox, digits)

    transfer!

    expect(proven_ci.reload.contact_id).to eq(son.id)
    expect([copied_ci.reload.contact_id, copied_conversation.reload.contact_id]).to all(eq(mother.id))
  end

  it 'sweeps a conversation and a message created for the previous holder while the transfer ran', :aggregate_failures do
    number_ci, number_conversation = chat(mother, cloud_inbox, digits)
    entry = transfer!.entry
    late_conversation = create(:conversation, account: account, inbox: cloud_inbox, contact: son, contact_inbox: number_ci)
    late_conversation.update_columns(contact_id: mother.id) # rubocop:disable Rails/SkipsModelValidations
    late_message = create(:message, account: account, inbox: cloud_inbox, conversation: number_conversation, sender: mother, message_type: :incoming)

    Contacts::NumberHistoryTransferSweepJob.perform_now(account.id, son.id, entry['id'])

    expect(late_conversation.reload.contact_id).to eq(son.id)
    expect(late_message.reload.sender_id).to eq(son.id)
  end

  it 'schedules the sweep after commit' do
    chat(mother, cloud_inbox, digits)

    expect { transfer! }.to have_enqueued_job(Contacts::NumberHistoryTransferSweepJob).twice
  end

  describe 'manual revert' do
    it 'reports a dry run without changing anything, then reverts the history and records it', :aggregate_failures do
      number_ci, number_conversation = chat(mother, cloud_inbox, digits)
      entry = transfer!.entry

      dry = revert(entry)
      expect([dry.dry_run, dry.moved_contact_inboxes, dry.moved_conversations, dry.moved_messages]).to eq([true, 1, 1, 1])
      expect(number_ci.reload.contact_id).to eq(son.id)

      revert(entry, actor: agent, dry_run: false)

      expect(number_ci.reload.contact_id).to eq(mother.id)
      expect(number_conversation.reload.contact_id).to eq(mother.id)
      expect(number_conversation.messages.incoming.pluck(:sender_id)).to eq([mother.id])
      expect(number_conversation.messages.activity.count).to eq(2)
      expect(son.reload.phone_number).to eq(family_phone)
      expect(described_class.find_entry(son, entry['id'])['reverted_at']).to be_present
      expect { revert(entry, dry_run: false) }.to raise_error(described_class::Error)
    end

    it 'V1 returns the rows tied to the chat (CSAT answer, call) and the touches that followed it, and logs the moved rows',
       :aggregate_failures do
      _number_ci, number_conversation = chat(mother, cloud_inbox, digits)
      csat = create(:csat_survey_response, account: account, conversation: number_conversation, contact: mother,
                                           message: number_conversation.messages.outgoing.first)
      call = create(:call, account: account, inbox: cloud_inbox, contact: mother, conversation: number_conversation)
      follow_up = create(:reminder, account: account, conversation: number_conversation, remindable: number_conversation, status: :pending)

      entry = transfer!.entry
      expect([csat.reload.contact_id, call.reload.contact_id, follow_up.reload.target_contact_id]).to all(eq(son.id))
      expect(entry['conversation_rows']).to include('csat_survey_responses' => [csat.id], 'calls' => [call.id])

      revert(entry, restore_primary: true, dry_run: false)

      expect([number_conversation.reload.contact_id, csat.reload.contact_id, call.reload.contact_id]).to all(eq(mother.id))
      expect(follow_up.reload).to have_attributes(target_contact_id: mother.id, target_conversation_id: number_conversation.id)
      revert_entry = mother.reload.custom_attributes[Contacts::SharedPhone::TRANSFERS_KEY].first
      expect(revert_entry).to include('revert_of' => entry['id'], 'conversation_rows' => include('calls' => [call.id]))
    end

    it 'V1b moves the telephony endpoints of the number and the lead submissions of its chat, previews them and returns them',
       :aggregate_failures do
      number_ci, number_conversation = chat(mother, cloud_inbox, digits)
      endpoints = stub_const('SpecTelephonyContactEndpoint', Class.new(ApplicationRecord) { self.table_name = 'telephony_contact_endpoints' })
      endpoint = { account_id: account.id, contact_id: mother.id, provider: 'sipuni', endpoint_type: 'phone' }
      number_endpoint = endpoints.create!(endpoint.merge(endpoint_value: digits))
      own_endpoint = endpoints.create!(endpoint.merge(endpoint_value: '77000000008'))
      lead_form = create(:lead_form, account: account, inbox: cloud_inbox)
      by_identity = create(:lead_submission, account: account, lead_form: lead_form, contact: mother, contact_inbox: number_ci)
      by_chat = create(:lead_submission, account: account, lead_form: lead_form, contact: mother, conversation: number_conversation)
      unrelated = create(:lead_submission, account: account, lead_form: lead_form, contact: mother)
      preview = Contacts::NumberHistoryTransferPreview.new(account: account, phone: family_phone, card: son, previous_holder: mother)
      expect(preview.telephony_endpoint_count).to eq(1)

      entry = transfer!.entry

      expect(entry['telephony_endpoint_ids']).to eq([number_endpoint.id])
      expect(entry['conversation_rows']).to include('lead_submissions' => [by_identity.id, by_chat.id].sort)
      expect([number_endpoint, by_identity, by_chat].map { |row| row.reload.contact_id }).to all(eq(son.id))
      expect([own_endpoint, unrelated].map { |row| row.reload.contact_id }).to all(eq(mother.id))

      revert(entry, dry_run: false)

      expect([number_endpoint, own_endpoint, by_identity, by_chat, unrelated].map { |row| row.reload.contact_id }).to all(eq(mother.id))
    end

    context 'with an amendment (a WhatsApp Web LID chat proven tied after the transfer)' do
      let(:web_inbox) { create(:channel_whatsapp_web, account: account).inbox }

      it 'R3 reverts the amendment with the transfer', :aggregate_failures do
        phone_ci, = chat(mother, web_inbox, digits)
        mother.update!(identifier: 'whatsapp_web:55555@lid')
        entry = transfer!.entry
        lid_ci, lid_conversation = chat(mother, web_inbox, '55555@lid')
        described_class.amend_tied_lid!(contact_inbox: phone_ci.reload, lid_source_id: '55555@lid')
        expect(lid_conversation.reload.contact_id).to eq(son.id)

        result = revert(entry, dry_run: false)

        expect(result.moved_conversations).to eq(2)
        expect([phone_ci.reload.contact_id, lid_ci.reload.contact_id, lid_conversation.reload.contact_id]).to all(eq(mother.id))
        expect(lid_conversation.messages.incoming.pluck(:sender_id)).to eq([mother.id])
        expect(mother.reload.identifier).to eq('whatsapp_web:55555@lid')
        log = son.reload.custom_attributes[Contacts::SharedPhone::TRANSFERS_KEY]
        expect(log.select { |item| item['direction'] == 'in' }.pluck('reverted_at')).to all(be_present)
      end
    end

    it 'restores the number to the previous holder when asked and its primary is blank', :aggregate_failures do
      mother.update!(phone_number: nil)
      chat(mother, cloud_inbox, digits)
      entry = transfer!.entry

      revert(entry, restore_primary: true, dry_run: false)

      expect(son.reload.phone_number).to be_nil
      expect(son.custom_attributes).to include('secondary_phones' => [family_phone], Contacts::SharedPhone::SHARED_OWNER_KEY => mother.id)
      expect(mother.reload.phone_number).to eq(family_phone)
    end
  end
end
