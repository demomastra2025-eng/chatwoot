require 'rails_helper'

RSpec.describe Captain::Tools::Agent::PatientBookingContext do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:mother) { create(:contact, account: account, name: 'Test Mother', phone_number: '+77010000001') }
  let(:conversation) { create(:conversation, account: account, contact: mother) }
  let(:details) { { first_name: 'Test', last_name: 'Son', iin: '940720300129', birth_date: '1994-07-20', phone: '+77010000002' } }

  def resolve(patient = details)
    described_class.new(assistant: assistant, conversation: conversation, patient: patient).perform
  end

  it 'creates a distinct patient with another phone, preserves the caller and reuses the same card on retry' do
    original = mother.reload.attributes
    result = resolve
    card = account.contacts.find(result[:patient_contact_id])
    expect(card.id).not_to eq(mother.id)
    expect(card.phone_number).to eq('+77010000002')
    expect(mother.reload.attributes).to eq(original)
    expect(conversation.reload.contact_id).to eq(mother.id)
    expect(resolve[:patient_contact_id]).to eq(card.id)
    expect(Captain::Tools::Agent::AppointmentAccess.valid_patient_selection?(
      token: result[:patient_selection_token], assistant: assistant, contact: mother, patient_id: card.id
    )).to be(true)
  end

  it 'reuses a recorded exact IIN without rewriting its clinical identity or phone' do
    card = create(:contact, account: account, name: 'Test', last_name: 'Son', middle_name: 'Recorded', phone_number: '+77010000003',
                            identifier: '940720300129', custom_attributes: {
                              Contacts::SharedPhone::CARD_KEY => true, 'iin' => '940720300129', 'birth_date' => '1994-07-20'
                            })
    original = card.reload.attributes
    expect(resolve[:patient_contact_id]).to eq(card.id)
    expect(card.reload.attributes).to eq(original)
    expect { resolve(details.merge(last_name: 'Other')) }.to raise_error(ArgumentError, /name/)
    expect { resolve(details.merge(birth_date: '1994-07-21')) }.to raise_error(ArgumentError, /birth date/)
    expect(card.reload.attributes).to eq(original)
  end

  it 'does not adopt self-declared public IIN or a matching card from another workspace' do
    public_card = create(:contact, account: account, identifier: '940720300129')
    foreign = create(:contact, identifier: '940720300129', custom_attributes: { Contacts::SharedPhone::CARD_KEY => true })
    result = resolve
    expect(result[:patient_contact_id]).not_to eq(public_card.id)
    expect(result[:patient_contact_id]).not_to eq(foreign.id)
  end

  it 'rejects invalid identity and cross-account context before creating a patient' do
    expect { resolve(details.merge(iin: '123456789012')) }.to raise_error(ArgumentError)
    expect { resolve(details.merge(birth_date: '1994-02-31')) }.to raise_error(ArgumentError)
    expect do
      described_class.new(assistant: create(:captain_assistant), conversation: conversation, patient: details).perform
    end.to raise_error(ArgumentError)
    expect(account.contacts.count).to eq(1)
  end
end
