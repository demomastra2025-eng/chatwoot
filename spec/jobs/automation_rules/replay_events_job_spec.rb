require 'rails_helper'

RSpec.describe AutomationRules::ReplayEventsJob do
  it 'replays pending and expired-lease events but skips completed and actively leased rows' do
    pending = create(:automation_event)
    expired = create(:automation_event, status: 'processing', lease_owner: 'dead', lease_expires_at: 1.minute.ago)
    create(:automation_event, status: 'completed')
    create(:automation_event, status: 'processing', lease_owner: 'live', lease_expires_at: 1.minute.from_now)
    allow(AutomationRules::PublishEventJob).to receive(:perform_later!)

    with_modified_env(AUTOMATION_DURABLE_EVENT_PUBLICATION_ENABLED: 'true') { described_class.perform_now }

    expect(AutomationRules::PublishEventJob).to have_received(:perform_later!).with(pending.id, kind_of(String)).once
    expect(AutomationRules::PublishEventJob).to have_received(:perform_later!).with(expired.id, kind_of(String)).once
    expect(expired.reload).to have_attributes(status: 'retrying', lease_owner: nil, lease_expires_at: nil)
  end

  it 'persists retry timing and continues after any queue adapter StandardError' do
    failed = create(:automation_event)
    following = create(:automation_event)
    allow(AutomationRules::PublishEventJob).to receive(:perform_later!)
    allow(AutomationRules::PublishEventJob).to receive(:perform_later!).with(failed.id, anything).and_raise(Redis::BaseError, 'queue unavailable')

    expect do
      with_modified_env(AUTOMATION_DURABLE_EVENT_PUBLICATION_ENABLED: 'true') { described_class.perform_now }
    end.not_to raise_error
    expect(AutomationRules::PublishEventJob).to have_received(:perform_later!).with(following.id, kind_of(String)).once
    expect(failed.reload).to have_attributes(status: 'retrying')
    expect(failed.next_attempt_at).to be > Time.current
    expect(failed.last_error).to include('Redis::BaseError: queue unavailable')
  end

  it 'reserves wakeups so repeated cron runs are idempotent and rows after the first 100 are fair' do
    events = create_list(:automation_event, 101)
    allow(AutomationRules::PublishEventJob).to receive(:perform_later!)

    with_modified_env(AUTOMATION_DURABLE_EVENT_PUBLICATION_ENABLED: 'true') do
      described_class.perform_now
      described_class.perform_now
      described_class.perform_now
    end

    expect(AutomationRules::PublishEventJob).to have_received(:perform_later!).exactly(101).times
    expect(AutomationRules::PublishEventJob).to have_received(:perform_later!).with(events.last.id, kind_of(String)).once
    expect(events.map { |event| event.reload.next_attempt_at }).to all(be > Time.current)
  end

  it 'does not activate new worker classes before the rolling-worker gate is enabled' do
    create(:automation_event)
    allow(AutomationRules::Events::WakeupService).to receive(:enqueue_batch!)

    with_modified_env(AUTOMATION_DURABLE_EVENT_PUBLICATION_ENABLED: 'false') { described_class.perform_now }

    expect(AutomationRules::Events::WakeupService).not_to have_received(:enqueue_batch!)
  end
end
