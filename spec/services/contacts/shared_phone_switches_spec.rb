require 'rails_helper'
require 'rake'

# Owner decision 2026-09-30: the shared-number core ships with automatic promotion, manual promotion and chat-history
# transfer switched off. With the shipped defaults no entry point moves a chat, ContactInbox, message, telephony endpoint
# or touch between contacts, and no number becomes a card's primary.
RSpec.describe Contacts::SharedPhoneSwitches do
  include ActiveJob::TestHelper

  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-api-key',
                      'FRONTEND_URL' => 'https://app.example.com') { example.run }
  end

  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }).tap { |record| record.enable_features!('scheduling') } }
  let(:phone) { SharedPhoneHelpers::FAMILY_PHONE }
  let(:digits) { phone.delete('+') }
  let(:mother) { create(:contact, account: account, name: 'Mother', phone_number: phone) }
  let(:cloud_inbox) { shared_phone_cloud_inbox(account) }
  let(:card) { shared_phone_card(account, mother) }
  let!(:number_chat) { shared_phone_chat(account, mother, cloud_inbox, digits) }

  before do
    stub_request(:any, /.*/).to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO telephony_contact_endpoints (account_id, contact_id, provider, endpoint_type, endpoint_value, created_at, updated_at)
      VALUES (#{account.id}, #{mother.id}, 'sipuni', 'phone', '#{digits}', NOW(), NOW())
    SQL
    create(:reminder, account: account, conversation: number_chat.last, remindable: number_chat.last, status: :pending)
  end

  def rows(scope, *columns) = scope.order(:id).pluck(:id, *columns)

  # Everything that a history transfer or a promotion would change, for the whole account.
  def state
    chat_state.merge(
      contacts: rows(Contact.where(account_id: account.id), :phone_number, :identifier),
      endpoints: ActiveRecord::Base.connection.select_rows(
        "SELECT id, contact_id FROM telephony_contact_endpoints WHERE account_id = #{account.id} ORDER BY id"
      ),
      touches: rows(Reminder.where(account_id: account.id), :target_contact_id, :target_contact_inbox_id, :target_conversation_id),
      transfer_logs: Contact.where(account_id: account.id).where('custom_attributes ? :key', key: Contacts::SharedPhone::TRANSFERS_KEY).count
    )
  end

  def chat_state
    { contact_inboxes: rows(ContactInbox.joins(:inbox).where(inboxes: { account_id: account.id }), :contact_id),
      conversations: rows(Conversation.where(account_id: account.id), :contact_id),
      messages: rows(Message.where(account_id: account.id).where.not(message_type: :activity), :sender_type, :sender_id),
      activity_messages: Message.where(account_id: account.id, message_type: :activity).count }
  end

  it 'ships every capability switched off and reads only the installation config', :aggregate_failures do
    expect(described_class.states).to eq(described_class::KEYS.index_with(false))
    expect(described_class.auto_promotion?).to be(false)
    expect(described_class.manual_promotion?).to be(false)
    expect(described_class.history_transfer?).to be(false)

    with_modified_env(described_class::AUTO_PROMOTION => 'true', described_class::HISTORY_TRANSFER => 'true') do
      expect(described_class.states.values).to all(be(false))
    end
    enable_shared_phone_switches!(described_class::MANUAL_PROMOTION)
    expect(described_class.states).to eq(described_class::AUTO_PROMOTION => false, described_class::MANUAL_PROMOTION => true,
                                         described_class::HISTORY_TRANSFER => false)
  end

  context 'with the shipped defaults (every switch off)' do
    it 'MedElement sync of the card promotes nothing and enqueues nothing', :aggregate_failures do
      client = instance_double(Integrations::Medelement::Client)
      patient = { 'PROFILE_CODE' => 'son-1', 'FULLNAME' => 'Patient Son', 'LASTNAME' => 'Patient', 'NAME' => 'Son', 'BIRTHDAY' => '01.01.2015',
                  'GENDER' => 2, 'PATIENT_PHONE_2_STR' => '+7 700 000 0009' }
      allow(client).to receive(:search_patients_by_codes).and_return([patient])
      mother.update!(phone_number: '+77000000008') # the number is free: only the switch keeps it from being promoted
      before_state = state

      resolver = Integrations::Medelement::ContactResolverService.new(account: account, client: client, organization_id: 'company-1')
      expect { resolver.sync_patient_payload!(patient, preferred_contact: card) }.not_to have_enqueued_job(Contacts::SharedPhonePromotionJob)
      expect(Contacts::SharedPhonePromotionJob.perform_now(card.id)).to have_attributes(status: :blocked, reason: :kill_switch)

      expect(card.reload.phone_number).to be_nil
      expect(state.except(:contacts)).to eq(before_state.except(:contacts))
    end

    it 'a primary number change of the holder only records a hint and moves nothing', :aggregate_failures do
      card
      before_state = state

      perform_enqueued_jobs(only: Contacts::SharedPhoneReleasedJob) { mother.update!(phone_number: '+77000000008') }

      expect(card.reload.phone_number).to be_nil
      expect(Contacts::SharedPhonePresenter.new(contact: card).as_json).to include(manual_promotion_enabled: false, hint: nil, promotion_preview: nil)
      expect(state.except(:contacts)).to eq(before_state.except(:contacts))
    end

    it 'the promote API path (administrator basis) refuses before reading anything', :aggregate_failures do
      mother.update!(phone_number: '+77000000008')
      card
      before_state = state

      expect { Contacts::SharedPhonePromotionService.new(card: card, basis: 'administrator', expected_fingerprint: 'x').perform }
        .to raise_error(Contacts::SharedPhonePromotionService::Error) { |error| expect(error.code).to eq('SHARED_PHONE_PROMOTION_DISABLED') }
      expect(state).to eq(before_state)
    end

    it 'WhatsApp Web and Telegram syncs of the number never move a chat to or from the card', :aggregate_failures do
      card.update!(phone_number: '+77000000061')
      web_inbox = create(:channel_whatsapp_web, account: account).inbox
      shared_phone_chat(account, card, web_inbox, digits)
      lid_contact = create(:contact, account: account, name: 'Mother LID', identifier: 'whatsapp_web:66666@lid')
      shared_phone_chat(account, lid_contact, web_inbox, '66666@lid')
      telegram = create(:channel_telegram_personal, account: account, phone_number: '+77000000555')
      shared_phone_chat(account, mother, telegram.inbox, '55502')
      before_state = state

      WhatsappWeb::ContactSyncService.new(channel: web_inbox.channel, contact_payload: { remoteJid: "#{digits}@s.whatsapp.net",
                                                                                         remoteLid: '66666@lid', pushName: 'Mother' }).perform
      TelegramPersonal::ContactSyncService.new(inbox: telegram.inbox, params: { peer_user_id: '55502', chat_id: '55502', first_name: 'Mother',
                                                                                phone_number: digits, sync_source: 'saved_contact' }).perform

      moved = %i[contact_inboxes conversations messages activity_messages endpoints touches transfer_logs]
      expect(state.slice(*moved)).to eq(before_state.slice(*moved))
      expect(card.reload.phone_number).to eq('+77000000061')
      expect(Contact.exists?(lid_contact.id)).to be(true)
    end

    context 'with a transfer recorded while history transfer was on' do
      let(:entry) do
        enable_shared_phone_switches!(described_class::HISTORY_TRANSFER)
        mother.update!(phone_number: '+77000000008')
        card.update!(phone_number: phone)
        recorded = Contacts::NumberHistoryTransferService.new(account: account, phone: phone, from: mother, to: card, basis: 'administrator',
                                                              promoted: true).perform!.entry
        disable_shared_phone_switches!
        recorded
      end

      it 'the rake revert, the sweep and the WhatsApp Web amendment move nothing back or forth', :aggregate_failures do
        entry
        before_state = state
        Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == 'onelink:shared_phones:revert_transfer' }
        task = Rake::Task['onelink:shared_phones:revert_transfer']
        task.reenable

        with_modified_env('ACCOUNT_ID' => account.id.to_s, 'CONTACT_ID' => card.id.to_s, 'TRANSFER_ID' => entry['id'], 'APPLY' => '1') do
          expect { task.invoke }.to raise_error(SystemExit).and output(/history_transfer_disabled/).to_stderr
        end
        Contacts::NumberHistoryTransferSweepJob.perform_now(account.id, card.id, entry['id'])
        expect(Contacts::NumberHistoryTransferService.amend_tied_lid!(contact_inbox: number_chat.first.reload, lid_source_id: '1@lid')).to be_nil

        expect(state).to eq(before_state)
        expect(Contacts::NumberHistoryTransferService.find_entry(card.reload, entry['id'])['reverted_at']).to be_nil
      end
    end
  end
end
