require 'rails_helper'

RSpec.describe Crm::Events::ReplayUnpublishedJob do
  let(:account) { create(:account) }

  before do
    allow(Crm::Events::PublishJob).to receive(:perform_later!)
  end

  around do |example|
    freeze_time { example.run }
  end

  it 'does not enqueue a duplicate while the publication lease is active' do
    unpublished = create(:crm_event, account: account, published_at: nil)
    expect(Crm::Events::PublishJob).not_to receive(:perform_later!).with(unpublished.id)

    described_class.perform_now
  end

  it 'recovers a lost job when its lease expires and coalesces consecutive replays' do
    unpublished = create(:crm_event, account: account, published_at: nil)
    travel_to unpublished.reload.publication_next_attempt_at
    expect(Crm::Events::PublishJob).to receive(:perform_later!).with(unpublished.id).once

    described_class.perform_now
    described_class.perform_now

    expect(unpublished.reload.publication_next_attempt_at).to eq(Crm::Event::PUBLICATION_LEASE.from_now)
  end

  it 'does not replay published events even after their retry deadline' do
    published = create(:crm_event, account: account, published_at: Time.current)
    travel Crm::Event::PUBLICATION_LEASE
    expect(Crm::Events::PublishJob).not_to receive(:perform_later!).with(published.id)

    described_class.perform_now
  end

  it 'persists an enqueue failure without preventing delivery of the next event' do
    failed = create(:crm_event, account: account)
    following = create(:crm_event, account: account)
    travel Crm::Event::PUBLICATION_LEASE
    allow(Crm::Events::PublishJob).to receive(:perform_later!).with(failed.id).and_raise(StandardError, 'queue unavailable')
    expect(Crm::Events::PublishJob).to receive(:perform_later!).with(following.id).once

    expect { described_class.perform_now }.not_to raise_error

    expect(failed.reload.published_at).to be_nil
    expect(failed.publication_attempts).to eq(1)
    expect(failed.publication_error).to eq('queue unavailable')
    expect(failed.publication_next_attempt_at).to eq(1.minute.from_now)
  end

  it 'backs off repeated failures and retries successfully after the deadline' do
    event = create(:crm_event, account: account)
    travel Crm::Event::PUBLICATION_LEASE
    allow(Crm::Events::PublishJob).to receive(:perform_later!).with(event.id).and_raise(StandardError, 'queue unavailable')
    described_class.perform_now
    deadline = event.reload.publication_next_attempt_at
    described_class.perform_now
    expect(event.reload.publication_attempts).to eq(1)

    travel_to deadline
    described_class.perform_now
    expect(event.reload.publication_attempts).to eq(2)
    expect(event.publication_next_attempt_at).to eq(2.minutes.from_now)

    travel_to event.publication_next_attempt_at
    allow(Crm::Events::PublishJob).to receive(:perform_later!).with(event.id).and_return(true)
    expect(Crm::Events::PublishJob).to receive(:perform_later!).with(event.id).once
    described_class.perform_now
    expect(event.reload.publication_next_attempt_at).to eq(Crm::Event::PUBLICATION_LEASE.from_now)
  end
end
