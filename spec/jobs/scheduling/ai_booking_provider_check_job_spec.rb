require 'rails_helper'

RSpec.describe Scheduling::AiBookingProviderCheckJob do
  let(:appointment) { instance_double(Scheduling::Appointment, account_id: 7) }
  let(:command) do
    instance_double(
      Integrations::Medelement::ProviderCommand,
      id: 31, account_id: 7, appointment_id: 12, appointment: appointment,
      request_snapshot_valid?: true, provider_reception_code: 'reception-31'
    )
  end
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:job) { described_class.new }

  before do
    allow(job).to receive(:candidates).and_return([[command, 'after_success']])
    allow(job).to receive(:client_for).and_return(client)
    allow(Redis::Alfred).to receive(:set).and_return(true)
    allow(Redis::Alfred).to receive(:incr).and_return(1)
    allow(Redis::Alfred).to receive(:delete)
    allow(Rails.logger).to receive(:error)
    allow(Rails.logger).to receive(:warn)
  end

  it 'does no work while the flag is absent' do
    with_modified_env(AI_BOOKING_PROVIDER_CHECK_ENABLED: nil) do
      expect(job).not_to receive(:candidates)
      job.perform
    end
  end

  it 'treats a 429 as not checked and allows a later retry' do
    allow(client).to receive(:get_reception).and_raise(Integrations::Medelement::Client::ApiError.new('rate limited', status: 429))

    with_modified_env(AI_BOOKING_PROVIDER_CHECK_ENABLED: 'true') { job.perform }

    expect(Redis::Alfred).to have_received(:delete).with('AI_BOOKING_PROVIDER_CHECK:31:after_success')
    expect(Rails.logger).not_to have_received(:error)
    expect(client).to have_received(:get_reception).once
  end

  it 'requires two independent mismatching reads before a critical log' do
    verifier = instance_double(Integrations::Medelement::ProviderCommands::ReceptionVerifier, destination_match?: false)
    allow(Integrations::Medelement::ProviderCommands::ReceptionVerifier).to receive(:new).and_return(verifier)
    allow(client).to receive(:get_reception).and_return({ 'REMOVED' => '1' })

    with_modified_env(AI_BOOKING_PROVIDER_CHECK_ENABLED: 'true') { job.perform }

    expect(client).to have_received(:get_reception).twice
    expect(Rails.logger).to have_received(:error).once.with(include('A3_PROVIDER_MISMATCH'))
  end

  it 'requires two not-found reads before a critical log' do
    allow(client).to receive(:get_reception).and_raise(Integrations::Medelement::Client::ApiError.new('missing', status: 404))

    with_modified_env(AI_BOOKING_PROVIDER_CHECK_ENABLED: 'true') { job.perform }

    expect(client).to have_received(:get_reception).twice
    expect(Rails.logger).to have_received(:error).once.with(include('A3_PROVIDER_MISMATCH'))
  end

  it 'does not report a mismatch when the second read matches' do
    verifier = instance_double(Integrations::Medelement::ProviderCommands::ReceptionVerifier)
    allow(verifier).to receive(:destination_match?).and_return(false, true)
    allow(Integrations::Medelement::ProviderCommands::ReceptionVerifier).to receive(:new).and_return(verifier)
    allow(client).to receive(:get_reception).and_return({ 'REMOVED' => '0' })

    with_modified_env(AI_BOOKING_PROVIDER_CHECK_ENABLED: 'true') { job.perform }

    expect(Rails.logger).not_to have_received(:error)
  end
end
