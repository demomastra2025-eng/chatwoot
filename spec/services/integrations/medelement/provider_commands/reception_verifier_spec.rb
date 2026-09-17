require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommands::ReceptionVerifier do
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
end
