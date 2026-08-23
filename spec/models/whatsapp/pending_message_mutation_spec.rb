require 'rails_helper'

RSpec.describe Whatsapp::PendingMessageMutation do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }

  it 'accepts an account-scoped pending mutation' do
    mutation = described_class.new(
      account: account,
      inbox: inbox,
      event_id: 'wamid.event-1',
      target_source_id: 'wamid.target-1',
      mutation_type: 'edit'
    )

    expect(mutation).to be_valid
  end

  it 'rejects an inbox from another account' do
    mutation = described_class.new(
      account: account,
      inbox: create(:inbox),
      event_id: 'wamid.event-1',
      target_source_id: 'wamid.target-1',
      mutation_type: 'edit'
    )

    expect(mutation).not_to be_valid
    expect(mutation.errors[:inbox]).to include('must belong to the same account')
  end

  it 'tracks invalid terminal state without retaining an exception message' do
    mutation = described_class.create!(
      account: account,
      inbox: inbox,
      event_id: 'wamid.event-2',
      target_source_id: 'wamid.target-2',
      mutation_type: 'edit'
    )

    mutation.mark_invalid!

    expect(mutation).to have_attributes(status: 'invalid', terminal_reason: 'invalid_payload')
    expect(mutation.terminal_at).to be_present
    expect(mutation.payload).to be_empty
    expect(mutation.payload_scrubbed_at).to be_present
  end

  it 'claims due reconciliation once and releases the matching claim' do
    mutation = described_class.create!(
      account: account,
      inbox: inbox,
      event_id: 'wamid.event-3',
      target_source_id: 'wamid.target-3',
      mutation_type: 'revoke'
    )

    token = mutation.claim_reconciliation!

    expect(token).to be_present
    expect(mutation.reload.reconciliation_token).to eq(token)
    expect(mutation.claim_reconciliation!).to be_nil
    expect(mutation.release_reconciliation_claim!('wrong-token')).to be(false)
    expect(mutation.release_reconciliation_claim!(token)).to be(true)
    expect(mutation.reload).to have_attributes(reconciliation_token: nil, next_reconciliation_at: nil)
  end
end
