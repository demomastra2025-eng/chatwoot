require 'rails_helper'

RSpec.describe Meta::InstagramCredentialHealthCheckJob do
  let(:scheduled_job) { instance_double(ActiveJob::ConfiguredJob, perform_later: true) }

  before do
    allow(Meta::ChannelCredentialHealthCheckJob).to receive(:set).and_return(scheduled_job)
  end

  it 'enqueues staggered checks for active Instagram channels and skips suspended accounts' do
    active_channel = create(:channel_instagram)
    suspended_channel = create(:channel_instagram)
    suspended_channel.account.update!(status: :suspended)

    described_class.new.perform

    expected_delay = (active_channel.id % described_class::MAX_JITTER_SECONDS).seconds
    expect(Meta::ChannelCredentialHealthCheckJob).to have_received(:set).with(wait: expected_delay).once
    expect(scheduled_job).to have_received(:perform_later).with(active_channel.class.name, active_channel.id).once
  end

  it 'bounds each scan and schedules the next cursor page with a delay' do
    stub_const("#{described_class}::BATCH_SIZE", 1)
    first_channel = create(:channel_instagram)
    create(:channel_instagram)
    continuation = instance_double(ActiveJob::ConfiguredJob, perform_later: true)
    allow(described_class).to receive(:set).with(wait: described_class::NEXT_BATCH_DELAY).and_return(continuation)

    described_class.new.perform

    expect(scheduled_job).to have_received(:perform_later).with(first_channel.class.name, first_channel.id).once
    expect(continuation).to have_received(:perform_later).with(first_channel.id).once
  end

  it 'continues strictly after the supplied channel cursor' do
    first_channel = create(:channel_instagram)
    second_channel = create(:channel_instagram)

    described_class.new.perform(first_channel.id)

    expect(scheduled_job).to have_received(:perform_later).with(second_channel.class.name, second_channel.id).once
  end

  it 'redacts credentials and raises a retryable enqueue failure instead of silently dropping the channel' do
    channel = create(:channel_instagram, access_token: 'instagram-secret-token')
    failed_job = instance_double(ActiveJob::ConfiguredJob)
    allow(failed_job).to receive(:perform_later).and_raise(StandardError, "boom #{channel[:access_token]}")
    allow(Meta::ChannelCredentialHealthCheckJob).to receive(:set).and_return(failed_job)

    expect { described_class.new.perform }.to raise_error(described_class::EnqueueError) do |error|
      expect(error.message).to include('[FILTERED]')
      expect(error.message).not_to include(channel[:access_token])
    end
  end
end
