require 'rails_helper'

RSpec.describe Integrations::Medelement::SampleCaptureSingleAttemptPolicy do
  let(:configuration) do
    instance_double(
      Integrations::Medelement::Configuration,
      integrator_key: 'synthetic-key',
      company_login: 'clinic-1',
      throttle_ms: 275,
      global_throttle_ms: 125,
      request_budget_per_minute: 30,
      live_reserve_per_minute: 10
    )
  end
  let(:limiter) { instance_double(Integrations::Medelement::RequestRateLimiter) }

  before do
    allow(Integrations::Medelement::RequestRateLimiter).to receive(:new)
      .with(
        integrator_key: 'synthetic-key',
        account_login: 'clinic-1',
        interval_ms: 275,
        global_interval_ms: 125,
        budget_per_minute: 30,
        live_reserve_per_minute: 10
      ).and_return(limiter)
    allow(Integrations::Medelement::RequestTelemetry).to receive(:new).and_return(
      instance_double(Integrations::Medelement::RequestTelemetry, record: nil)
    )
  end

  it 'paces one read attempt and refuses a write' do
    policy = described_class.new(configuration: configuration)
    expect(limiter).to receive(:wait!).once.with(operation: 'timetable', lane: :other_jobs)
    response = instance_double(HTTParty::Response, code: 200)
    expect(policy.call(operation: 'timetable') { response }).to eq(response)
    expect { policy.call(operation: 'reception create', write: true) { :unexpected } }
      .to raise_error(Integrations::Medelement::SampleCapture::Refused)
  end
end
