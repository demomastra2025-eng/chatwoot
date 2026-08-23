require 'rails_helper'

RSpec.describe Whatsapp::PendingMessageMutationReconciliationJob do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, inbox: inbox) }
  let(:pending_mutation) do
    Whatsapp::PendingMessageMutation.create!(
      account: account,
      inbox: inbox,
      event_id: 'wamid.edit-event',
      target_source_id: 'wamid.target',
      mutation_type: 'edit',
      provider_timestamp: 1_700_000_100,
      payload: { 'content' => 'Updated text' }
    )
  end

  it 'replays and removes the mutation when the target exists' do
    target = create(:message, conversation: conversation, inbox: inbox, source_id: 'wamid.target', content: 'Original text')

    described_class.perform_now(pending_mutation.id)

    expect(target.reload.content).to eq('Updated text')
    expect(Whatsapp::PendingMessageMutation.find_by(id: pending_mutation.id)).to be_nil
  end

  it 'persists a final reconciliation time for a non-expired orphan' do
    travel_to(Time.zone.parse('2026-08-23 12:00:00')) do
      pending_mutation

      expect { described_class.perform_now(pending_mutation.id) }.not_to have_enqueued_job(described_class)

      expect(pending_mutation.reload).to have_attributes(
        status: 'pending',
        attempt_count: 1,
        next_reconciliation_at: pending_mutation.expires_at
      )
    end
  end

  it 'marks an orphan exhausted after the bounded pending window' do
    pending_mutation_id = pending_mutation.id

    travel 8.days do
      described_class.perform_now(pending_mutation_id)
    end

    expect(pending_mutation.reload).to have_attributes(
      status: 'exhausted',
      terminal_reason: 'target_not_found_before_expiry',
      payload_scrubbed_at: nil
    )
    expect(pending_mutation.terminal_at).to be_present
    expect(pending_mutation.payload).to include('content' => 'Updated text')
  end

  it 'claims a due record once before enqueuing it' do
    pending_mutation
    clear_enqueued_jobs

    expect { described_class.enqueue_due(pending_mutation) }.to change(enqueued_jobs, :size).by(1)

    claim_token = pending_mutation.reload.reconciliation_token
    expect(claim_token).to be_present
    expect(pending_mutation.next_reconciliation_at).to be_future
    expect { described_class.enqueue_due(pending_mutation) }.not_to change(enqueued_jobs, :size)
  end

  it 'releases the durable claim when enqueueing fails' do
    allow(described_class).to receive(:perform_later).and_raise(StandardError, 'queue unavailable')

    expect { described_class.enqueue_due(pending_mutation) }.to raise_error(StandardError, 'queue unavailable')

    expect(pending_mutation.reload).to have_attributes(reconciliation_token: nil, next_reconciliation_at: nil)
  end

  it 'ignores a stale claimed job token' do
    pending_mutation.claim_reconciliation!
    target = create(:message, conversation: conversation, inbox: inbox, source_id: 'wamid.target', content: 'Original text')

    described_class.perform_now(pending_mutation.id, claim_token: 'stale-token')

    expect(target.reload.content).to eq('Original text')
    expect(pending_mutation.reload).to be_pending
  end

  it 'supports an explicit forced replay for an exhausted mutation during retention' do
    pending_mutation.mark_exhausted!
    target = create(:message, conversation: conversation, inbox: inbox, source_id: 'wamid.target', content: 'Original text')

    described_class.perform_now(pending_mutation.id, force: true)

    expect(target.reload.content).to eq('Updated text')
    expect(Whatsapp::PendingMessageMutation.find_by(id: pending_mutation.id)).to be_nil
  end

  it 'refuses forced replay after the exhausted payload retention window' do
    pending_mutation.mark_exhausted!

    travel 25.hours do
      pending_mutation.scrub_exhausted_payload!
      target = create(:message, conversation: conversation, inbox: inbox, source_id: 'wamid.target', content: 'Original text')

      described_class.perform_now(pending_mutation.id, force: true)

      expect(target.reload.content).to eq('Original text')
    end

    expect(pending_mutation.reload).to have_attributes(status: 'exhausted', payload: {})
    expect(pending_mutation.payload_scrubbed_at).to be_present
  end

  it 'refuses forced replay after retention when the payload sweep is delayed' do
    pending_mutation.mark_exhausted!
    pending_mutation.update!(terminal_at: 25.hours.ago)
    target = create(:message, conversation: conversation, inbox: inbox, source_id: 'wamid.target', content: 'Original text')

    described_class.perform_now(pending_mutation.id, force: true)

    expect(target.reload.content).to eq('Original text')
    expect(pending_mutation.reload).to have_attributes(status: 'exhausted', payload_scrubbed_at: nil)
  end
end
