require 'rails_helper'

RSpec.describe Integrations::Medelement::NomenclaturesSnapshotService do
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:sleeps) { [] }
  let(:snapshot) do
    described_class.new(
      client: client,
      sleeper: ->(seconds) { sleeps << seconds },
      page_delay_seconds: 0
    )
  end

  it 'retries only the failed page after a retryable transport error' do
    first_page = Array.new(20) do |index|
      { 'NOMENCLATURE_CODE' => "service-#{index}", 'RECCOUNT' => 21 }
    end
    last_page = [{ 'NOMENCLATURE_CODE' => 'service-20', 'RECCOUNT' => 21 }]
    transient_error = Integrations::Medelement::Client::ApiError.new('transport failed')
    page_attempts = 0

    allow(client).to receive(:nomenclatures).with(skip: 0).and_return(first_page)
    allow(client).to receive(:nomenclatures).with(skip: 20) do
      page_attempts += 1
      raise transient_error if page_attempts == 1

      last_page
    end

    result = snapshot.perform

    expect(result.size).to eq(21)
    expect(client).to have_received(:nomenclatures).with(skip: 0).once
    expect(client).to have_received(:nomenclatures).with(skip: 20).twice
    expect(sleeps).to eq([1])
  end

  it 'does not retry a non-retryable provider response' do
    error = Integrations::Medelement::Client::ApiError.new('invalid request', status: 400)
    allow(client).to receive(:nomenclatures).with(skip: 0).and_raise(error)

    expect { snapshot.perform }.to raise_error(error)
    expect(client).to have_received(:nomenclatures).with(skip: 0).once
    expect(sleeps).to be_empty
  end

  it 'stops after the bounded page retry budget is exhausted' do
    error = Integrations::Medelement::Client::ApiError.new('transport failed')
    allow(client).to receive(:nomenclatures).with(skip: 0).and_raise(error)

    expect { snapshot.perform }.to raise_error(error)
    expect(client).to have_received(:nomenclatures).with(skip: 0).exactly(4).times
    expect(sleeps).to eq([1, 5, 15])
  end
end
