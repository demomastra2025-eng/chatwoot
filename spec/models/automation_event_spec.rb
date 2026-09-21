require 'rails_helper'

RSpec.describe AutomationEvent do
  it 'builds a valid event from the factory' do
    expect(build(:automation_event)).to be_valid
  end

  it 'allows processing state changes but rejects envelope changes' do
    event = create(:automation_event)

    expect(event.update(status: 'processing', attempts: 1, lease_owner: 'worker-1', lease_expires_at: 1.minute.from_now)).to be(true)

    event.payload_snapshot = { 'forged' => true }
    expect(event).not_to be_valid
    expect(event.errors[:base]).to include(/payload_snapshot/)
  end

  it 'requires complete lease and dead-letter state' do
    event = build(:automation_event, lease_owner: 'worker-1', lease_expires_at: nil, status: 'dead', dead_at: nil)

    expect(event).not_to be_valid
    expect(event.errors[:lease_expires_at]).to be_present
    expect(event.errors[:dead_at]).to be_present
  end

  it 'requires status-coherent leases and exposes expired processing rows as ready' do
    pending_with_lease = build(:automation_event, lease_owner: 'worker-1', lease_expires_at: 1.minute.from_now)
    processing_without_lease = build(:automation_event, status: 'processing')
    expired = create(:automation_event, status: 'processing', lease_owner: 'dead-worker', lease_expires_at: 1.minute.ago)
    active = create(:automation_event, status: 'processing', lease_owner: 'live-worker', lease_expires_at: 1.minute.from_now)

    expect(pending_with_lease).not_to be_valid
    expect(processing_without_lease).not_to be_valid
    expect(described_class.ready).to include(expired)
    expect(described_class.ready).not_to include(active)
    expect(described_class.expired_leases).to contain_exactly(expired)
  end

  it 'requires resolvable same-account causation with a shared trace and incremented depth' do
    parent = create(:automation_event)
    child = build(
      :automation_event,
      account: parent.account,
      causation_event: parent,
      causation_id: parent.event_uuid,
      trace_id: parent.trace_id,
      depth: 1
    )

    expect(child).to be_valid
    child.trace_id = SecureRandom.uuid
    child.depth = 2
    expect(child).not_to be_valid
    expect(child.errors[:trace_id]).to be_present
    expect(child.errors[:depth]).to be_present
  end

  it 'requires non-empty object payload and provenance snapshots' do
    event = build(:automation_event, payload_snapshot: {}, changes_snapshot: [], provenance: {})

    expect(event).not_to be_valid
    expect(event.errors[:payload_snapshot]).to be_present
    expect(event.errors[:changes_snapshot]).to be_present
    expect(event.errors[:provenance]).to be_present
  end
end
