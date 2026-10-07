require 'rails_helper'

RSpec.describe Integrations::Medelement::Client do
  let(:request) { instance_double(Integrations::Medelement::Request) }
  let(:client) { described_class.new(configuration: instance_double(Integrations::Medelement::Configuration)) }

  before do
    allow(Integrations::Medelement::Request).to receive(:new).and_return(request)
  end

  it 'uses GET with a clinic-local minute timestamp and accepts an array' do
    allow(request).to receive(:call).and_return([{ 'RECEPTION_CODE' => 'fake-code' }])

    expect(client.receptions_by_update_date(update_date_from: '07.10.2026 10:00')).to eq(
      [{ 'RECEPTION_CODE' => 'fake-code' }]
    )
    expect(request).to have_received(:call).with(
      :get, '/v1/doctor/receptions/by_update_date',
      operation: 'receptions delta', query: { update_date_from: '07.10.2026 10:00' }
    )
  end

  it 'turns a provider 400 into a clear sanitized date error' do
    allow(request).to receive(:call).and_raise(described_class::ApiError.new('provider body', status: 400))

    expect { client.receptions_by_update_date(update_date_from: 'invalid') }
      .to raise_error(described_class::ApiError, 'Medelement receptions delta date was rejected')
  end
end
