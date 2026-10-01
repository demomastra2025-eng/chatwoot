require 'rails_helper'

# Round-8 widget identify probes (R6-R9) and the M8 fix: a patient card is merged from identify only with its HMAC
# verified identifier; visitor-supplied values never prove a patient identity or write server-owned attributes.
RSpec.describe ContactIdentifyAction do
  let(:account) { create(:account) }
  let(:card) do
    create(:contact, account: account, name: 'Relative', phone_number: '+77000000002', email: 'relative@example.com',
                     identifier: 'patient-ext-1', custom_attributes: { 'medelement_patient_card' => true, 'iin' => '940720300129' })
  end
  let(:visitor) { create(:contact, account: account, name: 'Visitor') }

  it 'R6 keeps a visitor with the card phone and email separate' do
    card
    result = described_class.new(contact: visitor, params: { phone_number: '+77000000002', email: 'relative@example.com' }).perform

    expect(result.id).to eq(visitor.id)
    expect(Contact.exists?(card.id)).to be(true)
  end

  it 'R7 keeps a visitor that declared the card IIN on itself separate' do
    card
    visitor.update!(custom_attributes: { 'iin' => '940720300129' })
    result = described_class.new(contact: visitor, params: { email: 'relative@example.com' }).perform

    expect(result.id).to eq(visitor.id)
    expect(Contact.exists?(visitor.id)).to be(true)
    expect(card.reload.email).to eq('relative@example.com')
  end

  it 'R8 keeps a visitor that sends the card identifier without HMAC verification separate' do
    card
    result = described_class.new(contact: visitor, params: { identifier: 'patient-ext-1', name: 'Visitor' }).perform

    expect(result.id).to eq(visitor.id)
    expect(visitor.reload.identifier).to be_nil
  end

  it 'R9 keeps the chat owner of a card appointment and the card when identified by the card email', :aggregate_failures do
    owner = create(:contact, account: account, name: 'Owner', phone_number: '+77000000001')
    create(:scheduling_appointment, account: account, contact: owner, patient_contact: card)
    result = described_class.new(contact: owner, params: { email: 'relative@example.com' }).perform

    expect(result.id).to eq(owner.id)
    expect(Contact.exists?(card.id)).to be(true)
  end

  it 'merges into the card when the HMAC verified identifier is the card identifier' do
    card
    result = described_class.new(contact: visitor, params: { identifier: 'patient-ext-1' }, hmac_verified: true).perform

    expect(result.id).to eq(card.id)
    expect(Contact.exists?(visitor.id)).to be(false)
  end

  it 'drops server-owned custom attributes supplied by the visitor' do
    params = { custom_attributes: { 'favourite' => 'blue', 'medelement_patient_card' => true, 'secondary_phones' => ['+77000000009'],
                                    'medelement_shared_phone_owner_contact_id' => card.id, 'medelement_number_transfers' => [{}] } }
    result = described_class.new(contact: visitor, params: params).perform

    expect(result.reload.custom_attributes).to eq({ 'favourite' => 'blue' })
  end

  it 'does not take a number reserved for an unresolved hidden share' do
    owner = create(:contact, account: account, phone_number: nil)
    create(:contact, account: account, custom_attributes: {
             'medelement_patient_card' => true, 'secondary_phones' => ['+77000000009'], 'medelement_shared_phone_number' => '+77000000009',
             'medelement_shared_phone_owner_contact_id' => owner.id, 'medelement_shared_phone_via' => 'booking_chat'
           })

    expect(described_class.new(contact: visitor, params: { phone_number: '+77000000009' }).perform.reload.phone_number).to be_nil
    expect(described_class.new(contact: visitor, params: { phone_number: '+7 700 000 00 09' }).perform.reload.phone_number).to be_nil
    expect(described_class.new(contact: owner, params: { phone_number: '+77000000009' }).perform.reload.phone_number).to eq('+77000000009')
  end

  it 'H2 does not take a released family number that a card keeps as доп. номер; its recorded owner can take it back', :aggregate_failures do
    mother = create(:contact, account: account, name: 'Mother', phone_number: '+77000000008')
    create(:contact, account: account, custom_attributes: {
             'medelement_patient_card' => true, 'secondary_phones' => ['+77000000009'], 'medelement_shared_phone_number' => '+77000000009',
             'medelement_shared_phone_owner_contact_id' => mother.id, 'medelement_shared_phone_via' => 'owner_primary'
           })

    expect(described_class.new(contact: visitor, params: { phone_number: '+77000000009' }).perform.reload.phone_number).to be_nil
    expect(described_class.new(contact: mother, params: { phone_number: '+77000000009' }).perform.reload.phone_number).to eq('+77000000009')
  end
end
