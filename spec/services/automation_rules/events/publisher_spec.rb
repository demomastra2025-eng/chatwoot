require 'rails_helper'

RSpec.describe AutomationRules::Events::Publisher do
  before do
    allow(AutomationRules::PublishEventJob).to receive(:perform_later!)
  end

  it 'claims and completes a ready envelope without redispatching legacy listeners' do
    event = create(:automation_event)
    allow(Rails.configuration.dispatcher).to receive(:dispatch)

    described_class.new(event.id, worker_id: 'worker-1').perform

    expect(event.reload).to have_attributes(status: 'completed', attempts: 1, lease_owner: nil, lease_expires_at: nil)
    expect(Rails.configuration.dispatcher).not_to have_received(:dispatch)
  end

  it 'does not reclaim an active lease and reclaims it after expiry' do
    event = create(:automation_event)
    first_publisher = described_class.new(event.id, worker_id: 'crashed-worker')

    first_publisher.claim!
    expect(described_class.new(event.id, worker_id: 'early-worker').perform).to be_nil
    expect(event.reload).to have_attributes(status: 'processing', attempts: 1, lease_owner: 'crashed-worker')

    travel_to event.lease_expires_at + 1.second do
      described_class.new(event.id, worker_id: 'recovery-worker').perform
    end

    expect(event.reload).to have_attributes(status: 'completed', attempts: 2, lease_owner: nil)
  end

  it 'persists retry state when delivery fails after claim' do
    event = create(:automation_event)
    publisher = described_class.new(event.id, worker_id: 'worker-1')
    allow(publisher).to receive(:deliver).and_raise(StandardError, 'temporary failure')

    expect { publisher.perform }.to raise_error(StandardError, 'temporary failure')

    expect(event.reload).to have_attributes(status: 'retrying', attempts: 1, lease_owner: nil)
    expect(event.last_error).to eq('StandardError: temporary failure')
    expect(event.next_attempt_at).to be > Time.current
  end

  it 'claims only the exact persisted wakeup reservation token' do
    event = create(:automation_event)
    reserved_until = 5.minutes.from_now.change(nsec: 123_456_000)
    event.update!(next_attempt_at: reserved_until)

    expect(described_class.new(event.id, reservation_token: 1.minute.from_now.iso8601(6)).perform).to be_nil
    described_class.new(event.id, reservation_token: reserved_until.iso8601(6)).perform

    expect(event.reload).to be_completed
  end
end
