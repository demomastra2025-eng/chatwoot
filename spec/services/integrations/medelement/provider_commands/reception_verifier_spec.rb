require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommands::ReceptionVerifier do
  it 'accepts opaque or positive reception IDs but rejects zero and nonpositive numeric IDs' do
    values = ['reception-1', '42', 42, nil, ' ', '0', 0, '000', '0.0', '-1']

    expect(values.map { |value| described_class.valid_reception_code?(value) }).to eq(
      [true, true, true, false, false, false, false, false, false, false]
    )
  end

  it 'rejects malformed removal state for active and removed matches' do
    command = instance_double(
      Integrations::Medelement::ProviderCommand,
      request_snapshot: {},
      provider_patient_code: nil
    )
    verifier = described_class.new(command: command)
    reception = { 'REMOVED' => '0garbage' }

    expect(verifier.destination_match?(reception)).to be(false)
    expect(verifier.removed_match?(reception)).to be(false)
  end

  it 'does not match zero as a valid reception reference' do
    command = instance_double(Integrations::Medelement::ProviderCommand, request_snapshot: {}, provider_patient_code: nil)
    verifier = described_class.new(command: command)

    expect(verifier.reference_matches?({ 'RECEPTION_CODE' => '0' }, expected_code: '0')).to be(false)
    expect(verifier.reference_matches?({ 'RECEPTION_CODE' => '42' }, expected_code: '42')).to be(true)
  end
end
