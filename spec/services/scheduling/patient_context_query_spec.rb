require 'rails_helper'

RSpec.describe Scheduling::PatientContextQuery do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:resource) { create(:scheduling_resource, account: account) }

  def patient_ids
    described_class.new(account: account, contact: contact).patient_ids
  end

  it 'holds the contact alone when nobody is linked to it' do
    create(:contact, account: account)

    expect(patient_ids).to eq([contact.id])
  end

  it 'holds the patients of the appointments booked from the contact and the cards recorded as the contact\'s' do
    child = create(:contact, account: account)
    recorded = create(:contact, account: account, custom_attributes: { described_class::CONTACT_IDS_KEY => [contact.id] })
    create(:scheduling_appointment, account: account, contact: contact, patient_contact: child, resource: resource)
    create(:contact, account: account)

    expect(patient_ids).to contain_exactly(contact.id, child.id, recorded.id)
  end

  it 'never holds a patient of another account' do
    foreign_account = create(:account)
    foreign = create(:contact, account: foreign_account, custom_attributes: { described_class::CONTACT_IDS_KEY => [contact.id] })

    expect(patient_ids).not_to include(foreign.id)
  end

  it 'gives the ids of the patients the staff selector lists, the contact first' do
    child = create(:contact, account: account)
    create(:scheduling_appointment, account: account, contact: contact, patient_contact: child, resource: resource)
    query = described_class.new(account: account, contact: contact)

    expect(query.patients.map(&:id)).to eq([contact.id, child.id])
    expect(query.patient_ids).to match_array(query.patients.map(&:id))
  end
end
