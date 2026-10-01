require 'rails_helper'

# sc8rv1 RV1 (M8): the MedElement import never adopts a contact whose IIN only an unauthenticated widget visitor or public
# API client could have written; it would otherwise give that visitor the patient's code, name, phone and MedElement data.
RSpec.describe Integrations::Medelement::ContactResolverService do
  let(:account) { create(:account) }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:iin) { '940720300129' }
  let(:patient) do
    { 'PROFILE_CODE' => 'child-9', 'FULLNAME' => 'Patient Child Secret', 'LASTNAME' => 'Patient', 'NAME' => 'Child',
      'MIDDLENAME' => 'Secret', 'BIRTHDAY' => '02.03.2015', 'GENDER' => 2, 'IIN' => iin, 'PATIENT_PHONE_2_STR' => '+7 700 000 0077' }
  end
  let(:resolver) { described_class.new(account: account, client: client, organization_id: 'company-1') }

  before do
    allow(client).to receive(:get_patient).with(patient_code: 'child-9').and_return(patient)
    allow(client).to receive(:search_patients_by_codes).and_return([patient])
    allow_any_instance_of(Integrations::Medelement::PatientReadModelGuard).to receive(:conflict?).and_return(false) # rubocop:disable RSpec/AnyInstance
  end

  def visitor_with(inbox, hmac_verified: false, **attributes)
    create(:contact, account: account, name: 'Visitor', **attributes).tap do |contact|
      create(:contact_inbox, contact: contact, inbox: inbox, hmac_verified: hmac_verified)
    end
  end

  it 'RV1 creates a separate patient contact instead of adopting a widget visitor that typed the IIN', :aggregate_failures do
    visitor = visitor_with(create(:channel_widget, account: account).inbox, custom_attributes: { 'iin' => iin })

    resolved = resolver.sync_patient!('child-9')

    expect(resolved.id).not_to eq(visitor.id)
    expect(visitor.reload.custom_attributes).to eq('iin' => iin)
    expect(visitor).to have_attributes(name: 'Visitor', phone_number: nil)
    expect(resolved.custom_attributes).to include('medelement_patient_code' => 'child-9', 'medelement_iin' => iin)
  end

  it 'RV1 does not adopt a public API contact that sent the IIN as its identifier' do
    visitor = visitor_with(create(:channel_api, account: account, webhook_url: nil).inbox, identifier: iin)

    expect(resolver.sync_patient!('child-9').id).not_to eq(visitor.id)
  end

  it 'adopts the recorded patient card rather than a visitor that also typed the IIN' do
    visitor_with(create(:channel_widget, account: account).inbox, custom_attributes: { 'iin' => iin })
    card = create(:contact, account: account, name: 'Child', custom_attributes: { Contacts::SharedPhone::CARD_KEY => true, 'iin' => iin })

    expect(resolver.sync_patient!('child-9').id).to eq(card.id)
  end

  it 'still adopts a contact with the IIN that staff created, or whose widget identity was HMAC-verified', :aggregate_failures do
    staff_contact = create(:contact, account: account, name: 'Child', custom_attributes: { 'iin' => iin })
    expect(resolver.sync_patient!('child-9').id).to eq(staff_contact.id)

    other_account = create(:account)
    verified = create(:contact, account: other_account, name: 'Child', identifier: iin)
    create(:contact_inbox, contact: verified, inbox: create(:channel_widget, account: other_account).inbox, hmac_verified: true)
    other_resolver = described_class.new(account: other_account, client: client, organization_id: 'company-1')
    expect(other_resolver.sync_patient!('child-9').id).to eq(verified.id)
  end
end
