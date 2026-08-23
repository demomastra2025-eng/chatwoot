require 'rails_helper'

RSpec.describe Integrations::Medelement::AppointmentServiceBinding do
  let(:appointment) do
    instance_double(
      Scheduling::Appointment,
      custom_attributes: {
        described_class::BINDING_KEY => described_class::LOCAL_ONLY,
        described_class::LOCAL_CODES_KEY => ['service-1']
      }
    )
  end
  let(:binding) { described_class.new(appointment: appointment) }

  it 'preserves a local selection only for an explicit empty provider service list' do
    expect(binding.preserve_local_selection?('SERVICES' => [])).to be(true)
    expect(binding.preserve_local_selection?({})).to be(false)
    expect(binding.preserve_local_selection?('SERVICES' => [{ 'NOMENCLATURE_CODE' => 'service-1' }])).to be(false)
  end

  it 'keeps the local mode while recording the empty provider observation' do
    attributes = binding.local_only_attributes(['service-1', 'service-1', nil])

    expect(attributes).to eq(
      described_class::BINDING_KEY => described_class::LOCAL_ONLY,
      described_class::LOCAL_CODES_KEY => ['service-1'],
      described_class::PROVIDER_CODES_KEY => []
    )
  end

  it 'makes a non-empty provider service snapshot authoritative' do
    reception = { 'SERVICES' => [{ 'NOMENCLATURE_CODE' => 'service-2' }] }

    expect(binding.provider_identity_authoritative?(reception)).to be(true)
    expect(binding.provider_attributes(['service-2'])).to eq(
      described_class::BINDING_KEY => described_class::PROVIDER,
      described_class::PROVIDER_CODES_KEY => ['service-2']
    )
  end
end
