require 'rails_helper'

# M9: dry-run counts before enabling automatic promotion; counts only, no personal data.
RSpec.describe Contacts::SharedPhoneReport do
  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }
  let(:phone) { SharedPhoneHelpers::FAMILY_PHONE }

  it 'counts promotable, blocked and transferable shares without names or numbers', :aggregate_failures do
    mother = create(:contact, account: account, name: 'Mother Name', phone_number: '+77000000008')
    shared_phone_chat(account, mother, shared_phone_cloud_inbox(account), phone.delete('+'))
    card = shared_phone_card(account, mother, name: 'Son Name')
    hidden_owner = create(:contact, account: account, name: 'Hidden Owner', phone_number: nil)
    shared_phone_card(account, hidden_owner, phone: '+77000000007', via: 'booking_chat', code: 'other-1', name: 'Other Child')

    counts = described_class.new(account: account).counts
    json = counts.to_json

    expect(counts).to include('cards_with_shared_phone' => 2, 'would_auto_promote' => 1, 'blocked_owner_unresolved' => 1,
                              'hidden_unresolved' => 1, 'would_transfer_contact_inboxes' => 1, 'would_transfer_conversations' => 1,
                              'would_transfer_messages' => 1, 'shares_owner_primary' => 1, 'shares_booking_chat' => 1)
    expect(json).not_to include('77000000009', '77000000007', 'Mother Name', 'Son Name', 'son-1')
    expect(card.reload.phone_number).to be_nil
    expect(counts['report_complete']).to be(true)
  end

  it 'K2 counts release-1 patients that have not been synced since the deploy and marks the report incomplete', :aggregate_failures do
    mother = create(:contact, account: account, name: 'Mother Name', phone_number: '+77000000008')
    shared_phone_chat(account, mother, shared_phone_cloud_inbox(account), phone.delete('+'))
    # release-1 shape: linked, no primary, no share, no MedElement phone snapshot; one stored number the mother chats from
    create(:contact, account: account, name: 'Son Name', custom_attributes: { 'medelement_patient_code' => 'son-1', 'secondary_phones' => [phone] })
    create(:contact, account: account, name: 'Other', custom_attributes: { 'medelement_patient_code' => 'other-1' })

    counts = described_class.new(account: account).counts

    expect(counts).to include('patients_pending_first_sync' => 2, 'unrecorded_chat_identity_patients' => 1, 'report_complete' => false,
                              'would_auto_promote' => 0)
    expect(counts.to_json).not_to include('77000000009', 'Son Name', 'son-1')
  end

  it 'D3 completes after a full sync even when MedElement has no phone for a linked patient', :aggregate_failures do
    kid = { 'PROFILE_CODE' => 'kid-1', 'FULLNAME' => 'Patient Kid', 'LASTNAME' => 'Patient', 'NAME' => 'Kid', 'BIRTHDAY' => '01.01.2019',
            'GENDER' => 2 }
    client = instance_double(Integrations::Medelement::Client)
    allow(client).to receive(:search_patients_by_codes).with(patient_codes: ['kid-1']).and_return([kid])
    allow(client).to receive(:get_patient).with(patient_code: 'kid-1').and_return(kid)
    card = create(:contact, account: account, name: 'Kid', custom_attributes: { 'medelement_patient_code' => 'kid-1' })
    expect(described_class.new(account: account).counts).to include('patients_pending_first_sync' => 1, 'report_complete' => false)

    Integrations::Medelement::ContactResolverService.new(account: account, client: client, organization_id: 'company-1')
                                                    .sync_patient_payload!(kid, preferred_contact: card)

    expect(card.reload.custom_attributes).to include(Contacts::SharedPhone::MEDELEMENT_PHONE_KEY => '')
    expect(described_class.new(account: account).counts).to include('patients_pending_first_sync' => 0, 'report_complete' => true)
  end

  it 'counts cards that still own a chat of a number other than their primary (M7x flag)', :aggregate_failures do
    son = create(:contact, account: account, name: 'Son', phone_number: '+77000000061', custom_attributes: { 'medelement_patient_code' => 'son-1' })
    shared_phone_chat(account, son, create(:channel_whatsapp_web, account: account).inbox, phone.delete('+'))
    own = create(:contact, account: account, name: 'Own', phone_number: '+77000000062', custom_attributes: { 'medelement_patient_code' => 'own-1' })
    shared_phone_chat(account, own, shared_phone_cloud_inbox(account), '77000000062')

    expect(described_class.new(account: account).counts).to include('cards_with_chats_of_other_number' => 1)
  end
end
