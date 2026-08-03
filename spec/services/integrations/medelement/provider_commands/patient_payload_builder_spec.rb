require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommands::PatientPayloadBuilder do
  let(:contact) do
    create(
      :contact,
      name: 'Ivanov Ivan Ivanovich',
      phone_number: '+77001234567',
      email: 'patient@example.com',
      custom_attributes: {
        'medelement_birth_date' => '2000-01-02',
        'medelement_gender' => 'male',
        'medelement_iin' => '000000000000'
      }
    )
  end

  it 'builds the documented patient form fields' do
    payload = described_class.new(contact: contact, patient_code: 'patient-1').build

    expect(payload).to include(
      'profile_code' => 'patient-1',
      'lastname' => 'Ivanov',
      'name' => 'Ivan',
      'middlename' => 'Ivanovich',
      'patient_email' => 'patient@example.com',
      'birthday' => '02.01.2000',
      'gender' => 2,
      'patient_phone_2[0]' => '7',
      'patient_phone_2[1]' => '700',
      'patient_phone_2[2]' => '1234567',
      'iin' => '000000000000'
    )
  end

  it 'uses an explicit phone without changing the contact' do
    contact.update!(phone_number: nil)

    payload = described_class.new(contact: contact, phone_number: '+77001234567').build

    expect(payload).to include(
      'patient_phone_2[0]' => '7',
      'patient_phone_2[1]' => '700',
      'patient_phone_2[2]' => '1234567'
    )
    expect(contact.reload.phone_number).to be_nil
  end

  it 'rejects a name without separate first and last names' do
    contact.update!(name: 'Ivan')

    expect { described_class.new(contact: contact).build }
      .to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_PATIENT_NAME_INCOMPLETE') }
  end
end
