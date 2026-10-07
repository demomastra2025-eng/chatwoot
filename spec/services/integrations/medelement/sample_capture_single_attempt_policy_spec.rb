require 'rails_helper'

RSpec.describe Integrations::Medelement::SampleCaptureSingleAttemptPolicy do
  let(:configuration) do
    instance_double(Integrations::Medelement::Configuration, integrator_key: 'synthetic-key', throttle_ms: 275)
  end
  let(:limiter) { instance_double(Integrations::Medelement::RequestRateLimiter) }

  before do
    allow(Integrations::Medelement::RequestRateLimiter).to receive(:new)
      .with(integrator_key: 'synthetic-key', interval_ms: 275).and_return(limiter)
  end

  it 'paces one read attempt and refuses a write' do
    policy = described_class.new(configuration: configuration)
    expect(limiter).to receive(:wait!).once
    expect(policy.call(operation: 'timetable') { :answer }).to eq(:answer)
    expect { policy.call(operation: 'reception create', write: true) { :unexpected } }
      .to raise_error(Integrations::Medelement::SampleCapture::Refused)
  end
end
