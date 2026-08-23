require 'rails_helper'

RSpec.describe Whatsapp::PendingMessageMutationSweepJob do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }

  def create_mutation(event_id:, next_reconciliation_at: nil)
    Whatsapp::PendingMessageMutation.create!(
      account: account,
      inbox: inbox,
      event_id: event_id,
      target_source_id: "#{event_id}.target",
      mutation_type: 'edit',
      provider_timestamp: 1_700_000_100,
      payload: { 'content' => 'Sensitive customer text' },
      next_reconciliation_at: next_reconciliation_at
    )
  end

  it 'enqueues legacy and expired claims while leaving future records deduplicated' do
    legacy_mutation = create_mutation(event_id: 'wamid.legacy')
    expired_claim = create_mutation(event_id: 'wamid.expired', next_reconciliation_at: 1.minute.ago)
    future_mutation = create_mutation(event_id: 'wamid.future', next_reconciliation_at: 1.hour.from_now)
    allow(Whatsapp::PendingMessageMutationReconciliationJob).to receive(:enqueue_due).and_return(true)

    described_class.perform_now

    expect(Whatsapp::PendingMessageMutationReconciliationJob).to have_received(:enqueue_due).with(legacy_mutation)
    expect(Whatsapp::PendingMessageMutationReconciliationJob).to have_received(:enqueue_due).with(expired_claim)
    expect(Whatsapp::PendingMessageMutationReconciliationJob).not_to have_received(:enqueue_due).with(future_mutation)
  end

  it 'continues the batch after an enqueue failure' do
    failed_mutation = create_mutation(event_id: 'wamid.failed')
    next_mutation = create_mutation(event_id: 'wamid.next')
    allow(Whatsapp::PendingMessageMutationReconciliationJob).to receive(:enqueue_due) do |mutation|
      raise StandardError, 'queue unavailable' if mutation == failed_mutation

      true
    end

    expect { described_class.perform_now }.not_to raise_error

    expect(Whatsapp::PendingMessageMutationReconciliationJob).to have_received(:enqueue_due).with(next_mutation)
  end

  it 'scrubs exhausted payloads after the bounded retention window' do
    mutation = create_mutation(event_id: 'wamid.exhausted')
    mutation.mark_exhausted!
    mutation.update!(terminal_at: 25.hours.ago)

    described_class.perform_now

    expect(mutation.reload).to have_attributes(status: 'exhausted', payload: {})
    expect(mutation.payload_scrubbed_at).to be_present
  end

  it 'continues scrubbing after one record fails' do
    failed_mutation = create_mutation(event_id: 'wamid.scrub-failed')
    next_mutation = create_mutation(event_id: 'wamid.scrub-next')
    relation = instance_double(ActiveRecord::Relation)
    allow(Whatsapp::PendingMessageMutation).to receive(:due_for_payload_scrub).and_return(relation)
    allow(relation).to receive(:order).with(:id).and_return(relation)
    allow(relation).to receive(:limit).with(described_class::BATCH_SIZE).and_return([failed_mutation, next_mutation])
    allow(failed_mutation).to receive(:scrub_exhausted_payload!).and_raise(StandardError, 'database failure')
    allow(next_mutation).to receive(:scrub_exhausted_payload!)

    described_class.perform_now

    expect(next_mutation).to have_received(:scrub_exhausted_payload!)
  end
end
