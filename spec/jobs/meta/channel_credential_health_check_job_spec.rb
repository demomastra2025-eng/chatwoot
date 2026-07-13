require 'rails_helper'

RSpec.describe Meta::ChannelCredentialHealthCheckJob do
  let(:channel) { create(:channel_instagram) }
  let(:result) do
    Meta::AuthorizationHealthCheckService::Result.new(status: :healthy, reason: 'healthy', metadata: {})
  end
  let(:health_service) { instance_double(Meta::ChannelCredentialHealthCheckService, perform: result) }

  before do
    allow(Meta::ChannelCredentialHealthCheckService).to receive(:new).with(channel).and_return(health_service)
  end

  def unlocked_job
    described_class.new.tap { |job| allow(job).to receive(:with_lock).and_yield }
  end

  it 'runs an active channel under a provider-scoped distributed lock' do
    job = unlocked_job

    job.perform(channel.class.name, channel.id)

    expect(job).to have_received(:with_lock)
      .with("META_CREDENTIAL_HEALTH:#{channel.class.name}:#{channel.id}", described_class::LOCK_TIMEOUT)
    expect(health_service).to have_received(:perform).once
  end

  it 'raises a retryable error after persisting a transient provider result' do
    transient = Meta::AuthorizationHealthCheckService::Result.new(
      status: :transient_failure,
      reason: 'provider_request_failed',
      metadata: {}
    )
    allow(health_service).to receive(:perform).and_return(transient)

    expect { unlocked_job.perform(channel.class.name, channel.id) }
      .to raise_error(described_class::TransientProviderError, 'provider_request_failed')
  end

  it 'skips channels in suspended accounts' do
    channel.account.update!(status: :suspended)

    unlocked_job.perform(channel.class.name, channel.id)

    expect(health_service).not_to have_received(:perform)
  end
end
