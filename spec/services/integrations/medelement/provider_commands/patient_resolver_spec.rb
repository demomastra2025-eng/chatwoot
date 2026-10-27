require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommands::PatientResolver do
  let(:command) do
    instance_double(
      Integrations::Medelement::ProviderCommand,
      request_snapshot: snapshot,
      contact: nil,
      execution_state: {},
      update!: true
    )
  end
  let(:resolver) { described_class.new(command: command, client: nil) }

  context 'when the patient is linked by code' do
    let(:snapshot) { { 'provider_patient_code' => 'fake-patient-1' } }

    it 'does not use a communication contact phone when the linked patient snapshot has none' do
      allow(command).to receive(:contact).and_return(instance_double(Contact, phone_number: '+77010000001'))
      expect { resolver.send(:record_phone_warning!, {}) }.not_to raise_error
      expect(command).not_to have_received(:update!)
    end

    it 'keeps the mismatch warning when a known phone differs from the card' do
      snapshot['patient_phone_numbers'] = ['+77010000001']
      resolver.send(:record_phone_warning!, 'PATIENT_PHONE_2' => '+77010000002')
      expect(command).to have_received(:update!).with(
        execution_state: hash_including('warnings' => [hash_including('code' => 'patient_phone_mismatch')])
      )
    end
  end
end
