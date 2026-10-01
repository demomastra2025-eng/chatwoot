require 'rails_helper'

# M5(a) is event driven: only a MedElement sync of that patient enqueues the promotion, after its commit.
RSpec.describe Contacts::SharedPhonePromotionJob do
  let(:account) { create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }) }
  let(:phone) { SharedPhoneHelpers::FAMILY_PHONE }
  let(:mother) { create(:contact, account: account, name: 'Mother', phone_number: '+77000000008') }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:resolver) { Integrations::Medelement::ContactResolverService.new(account: account, client: client, organization_id: 'company-1') }
  let(:patient) do
    { 'PROFILE_CODE' => 'son-1', 'FULLNAME' => 'Patient Son', 'LASTNAME' => 'Patient', 'NAME' => 'Son', 'BIRTHDAY' => '01.01.2015',
      'GENDER' => 2, 'PATIENT_PHONE_2_STR' => '+7 700 000 0009' }
  end
  let(:card) { shared_phone_card(account, mother, medelement_phone: nil) }

  before do
    # The behaviour with the capabilities switched on (they ship off, see Contacts::SharedPhoneSwitches).
    enable_shared_phone_switches!
    shared_phone_chat(account, mother, shared_phone_cloud_inbox(account), phone.delete('+'))
    allow(client).to receive(:search_patients_by_codes).with(patient_codes: ['son-1']).and_return([patient])
  end

  it 'is enqueued by the MedElement sync of the card and promotes it', :aggregate_failures do
    expect { resolver.sync_patient_payload!(patient, preferred_contact: card) }.to have_enqueued_job(described_class).with(card.id)
    expect(card.reload.custom_attributes[Contacts::SharedPhone::MEDELEMENT_PHONE_KEY]).to eq(phone)

    described_class.perform_now(card.id)
    expect(card.reload.phone_number).to eq(phone)
  end

  it 'is not enqueued when automatic promotion is switched off, and a job queued before promotes nothing', :aggregate_failures do
    disable_shared_phone_switches!(Contacts::SharedPhoneSwitches::AUTO_PROMOTION)

    expect { resolver.sync_patient_payload!(patient, preferred_contact: card) }.not_to have_enqueued_job(described_class)
    expect(described_class.perform_now(card.id)).to have_attributes(status: :blocked, reason: :kill_switch)
    expect(card.reload.phone_number).to be_nil
  end

  it 'promotes nothing while the chats of the number could not move (history transfer switched off)', :aggregate_failures do
    disable_shared_phone_switches!(Contacts::SharedPhoneSwitches::HISTORY_TRANSFER)
    resolver.sync_patient_payload!(patient, preferred_contact: card)

    expect(described_class.perform_now(card.id)).to have_attributes(status: :blocked, reason: :history_transfer_disabled)
    expect(card.reload.phone_number).to be_nil
    expect(ContactInbox.where(source_id: phone.delete('+')).pluck(:contact_id)).to eq([mother.id])
  end

  it 'leaves a MedElement hint instead of promoting when siblings share the number', :aggregate_failures do
    sibling = shared_phone_card(account, mother, code: 'daughter-1', name: 'Daughter')
    resolver.sync_patient_payload!(patient, preferred_contact: card)

    described_class.perform_now(card.id)

    expect(card.reload.phone_number).to be_nil
    expect(card.custom_attributes[Contacts::SharedPhone::HINT_KEY]).to include('reason' => 'medelement', 'phone' => phone,
                                                                               'candidate_contact_ids' => contain_exactly(card.id, sibling.id))
  end

  it 'never promotes a hidden-number share while its owner is unresolved' do
    mother.update!(phone_number: nil)
    card.update!(custom_attributes: card.custom_attributes.merge(Contacts::SharedPhone::SHARED_VIA_KEY => 'booking_chat'))
    resolver.sync_patient_payload!(patient, preferred_contact: card)

    described_class.perform_now(card.id)
    expect(card.reload.phone_number).to be_nil
  end
end
