require 'rails_helper'

# Owner model 2026-09-29 (M1/M2, F3): a MedElement patient sync never takes a number another contact holds, chats from,
# or has reserved through an unresolved hidden share; a card's own recorded доп. номер is never assigned here.
RSpec.describe Integrations::Medelement::ContactResolverService do
  include ActiveJob::TestHelper

  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:service) { described_class.new(account: account, client: client, organization_id: 'company-1') }
  let(:shared) { Contacts::SharedPhone }
  let(:family_phone) { '+77000000009' }

  # As before the switches existed (they ship off, see Contacts::SharedPhoneSwitches); what the resolver records does not
  # depend on them, only the automatic promotion afterwards does.
  before { enable_shared_phone_switches! }

  def payload(code, name:)
    { 'PROFILE_CODE' => code, 'FULLNAME' => "Patient #{name}", 'LASTNAME' => 'Patient', 'NAME' => name,
      'BIRTHDAY' => '01.01.2015', 'GENDER' => 2, 'PATIENT_PHONE_2_STR' => '+7 700 000 0009' }
  end

  def stub_patient(code, name:)
    patient = payload(code, name: name)
    allow(client).to receive(:get_patient).with(patient_code: code).and_return(patient)
    allow(client).to receive(:search_patients_by_codes).with(patient_codes: [code]).and_return([patient])
    patient
  end

  def hidden_share_card(owner, code:)
    create(:contact, account: account, name: 'Child', custom_attributes: {
             'medelement_patient_code' => code, 'secondary_phones' => [family_phone], shared::CARD_KEY => true,
             shared::SHARED_PHONE_KEY => family_phone, shared::SHARED_OWNER_KEY => owner.id, shared::SHARED_VIA_KEY => 'booking_chat',
             shared::SHARED_CONVERSATION_KEY => 77
           })
  end

  it 'F3 a sibling imported with a number reserved by a hidden share gets it only as доп. with the same owner', :aggregate_failures do
    owner = create(:contact, account: account, name: 'Mother', phone_number: nil)
    hidden_share_card(owner, code: 'child-1')
    stub_patient('child-2', name: 'Sister')

    sibling = service.sync_patient!('child-2')

    expect(sibling.phone_number).to be_nil
    expect(sibling.custom_attributes).to include('secondary_phones' => [family_phone], shared::SHARED_OWNER_KEY => owner.id,
                                                 shared::SHARED_VIA_KEY => 'booking_chat', shared::SHARED_CONVERSATION_KEY => 77)
    expect(shared.assignable_primary?(account_id: account.id, phone: family_phone, contact_id: owner.id)).to be(true)
  end

  it 'F3 never assigns the card own recorded доп. номер as primary, even when nobody holds it', :aggregate_failures do
    owner = create(:contact, account: account, name: 'Mother', phone_number: '+77000000008')
    card = hidden_share_card(owner, code: 'child-1')
    patient = stub_patient('child-1', name: 'Child')

    resolved = service.sync_patient_payload!(patient, preferred_contact: card)

    expect(resolved.id).to eq(card.id)
    expect(card.reload.phone_number).to be_nil
    expect(card.custom_attributes).to include(shared::SHARED_PHONE_KEY => family_phone, shared::SHARED_OWNER_KEY => owner.id,
                                              'secondary_phones' => [family_phone])
  end

  it 'F3 a number another contact chats from is shared with that contact', :aggregate_failures do
    stub_request(:post, 'https://waba.360dialog.io/v1/configs/webhook')
    inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
    chat = create(:contact, account: account, name: 'Mother', phone_number: '+77000000008')
    create(:contact_inbox, contact: chat, inbox: inbox, source_id: family_phone.delete('+'))
    stub_patient('child-2', name: 'Son')

    card = service.sync_patient!('child-2')

    expect(card.phone_number).to be_nil
    expect(card.custom_attributes).to include(shared::SHARED_OWNER_KEY => chat.id, shared::SHARED_VIA_KEY => 'owner_chat_identity')
  end

  it 'R1 a RESTORE_PRIMARY revert of an automatic promotion survives the next MedElement sync of the patient', :aggregate_failures do
    inbox = shared_phone_cloud_inbox(account)
    mother = create(:contact, account: account, name: 'Mother', phone_number: '+77000000008')
    _ci, conversation = shared_phone_chat(account, mother, inbox, family_phone.delete('+'))
    card = shared_phone_card(account, mother, code: 'child-1', medelement_phone: nil)
    patient = stub_patient('child-1', name: 'Child')

    perform_enqueued_jobs(only: Contacts::SharedPhonePromotionJob) { service.sync_patient_payload!(patient, preferred_contact: card) }
    expect([card.reload.phone_number, conversation.reload.contact_id]).to eq([family_phone, card.id])
    entry = card.custom_attributes[shared::TRANSFERS_KEY].first
    Contacts::NumberHistoryTransferRevertService.new(contact: card, transfer_id: entry['id'], restore_primary: true, dry_run: false).perform
    expect([card.reload.phone_number, conversation.reload.contact_id]).to eq([nil, mother.id])

    perform_enqueued_jobs(only: Contacts::SharedPhonePromotionJob) { service.sync_patient_payload!(patient, preferred_contact: card.reload) }

    expect(card.reload.phone_number).to be_nil
    expect(shared.secondary_phones(card)).to include(family_phone)
    expect(conversation.reload.contact_id).to eq(mother.id)
    expect(Contacts::SharedPhonePromotionPolicy.auto_decision(card).reason).to eq(:reverted_transfer)
  end

  it 'F3 a free number that is not a share still becomes the patient own primary' do
    stub_patient('child-2', name: 'Son')

    expect(service.sync_patient!('child-2').phone_number).to eq(family_phone)
  end
end
