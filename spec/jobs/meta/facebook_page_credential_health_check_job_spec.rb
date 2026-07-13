require 'rails_helper'

RSpec.describe Meta::FacebookPageCredentialHealthCheckJob do
  let(:scheduled_job) { instance_double(ActiveJob::ConfiguredJob, perform_later: true) }

  before do
    stub_request(:post, /graph\.facebook\.com/).to_return(status: 200, body: '{}', headers: {})
    allow(Meta::ChannelCredentialHealthCheckJob).to receive(:set).and_return(scheduled_job)
  end

  it 'enqueues staggered checks for active Facebook Page channels and skips suspended accounts' do
    active_channel = create(:channel_facebook_page)
    suspended_channel = create(:channel_facebook_page)
    suspended_channel.account.update!(status: :suspended)

    described_class.new.perform

    expected_delay = (active_channel.id % described_class::MAX_JITTER_SECONDS).seconds
    expect(Meta::ChannelCredentialHealthCheckJob).to have_received(:set).with(wait: expected_delay).once
    expect(scheduled_job).to have_received(:perform_later).with(active_channel.class.name, active_channel.id).once
  end

  it 'bounds each scan and schedules the next cursor page with a delay' do
    stub_const("#{described_class}::BATCH_SIZE", 1)
    first_channel = create(:channel_facebook_page)
    create(:channel_facebook_page)
    continuation = instance_double(ActiveJob::ConfiguredJob, perform_later: true)
    allow(described_class).to receive(:set).with(wait: described_class::NEXT_BATCH_DELAY).and_return(continuation)

    described_class.new.perform

    expect(scheduled_job).to have_received(:perform_later).with(first_channel.class.name, first_channel.id).once
    expect(continuation).to have_received(:perform_later).with(first_channel.id).once
  end

  it 'continues strictly after the supplied channel cursor' do
    first_channel = create(:channel_facebook_page)
    second_channel = create(:channel_facebook_page)

    described_class.new.perform(first_channel.id)

    expect(scheduled_job).to have_received(:perform_later).with(second_channel.class.name, second_channel.id).once
  end
end
