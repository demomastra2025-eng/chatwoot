require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::ActionApprovalService, '.discard!' do
  let(:account_id) { SecureRandom.random_number(1_000_000_000) + 1 }
  let(:conversation_id) { SecureRandom.random_number(1_000_000_000) + 1 }

  def card(id, status = 'pending')
    described_class.store_record!('action_id' => id, 'account_id' => account_id, 'conversation_id' => conversation_id, 'status' => status)
  end

  it 'rejects the pending cards it is given, with the reason and the time' do
    ids = [SecureRandom.uuid, SecureRandom.uuid]
    ids.each { |id| card(id) }

    described_class.discard!(action_ids: ids, reason: 'suggestion_run_aborted')

    ids.each do |id|
      expect(described_class.fetch_record(id)).to include('status' => 'rejected', 'rejected_reason' => 'suggestion_run_aborted')
      expect(described_class.fetch_record(id)['rejected_at']).to be_present
    end
  end

  it 'takes the cards out of the pending cards of the conversation' do
    id = SecureRandom.uuid
    card(id)
    expect(described_class.pending_for(account_id: account_id, conversation_id: conversation_id).pluck('action_id')).to eq([id])

    described_class.discard!(action_ids: [id], reason: 'suggestion_run_aborted')

    expect(described_class.pending_for(account_id: account_id, conversation_id: conversation_id)).to be_empty
  end

  it 'leaves alone the cards that were acted on, the cards it was not given, and what does not exist' do
    approved = SecureRandom.uuid
    other = SecureRandom.uuid
    card(approved, 'approved')
    card(other)

    described_class.discard!(action_ids: [approved, 'missing'], reason: 'suggestion_run_aborted')

    expect(described_class.fetch_record(approved)).to include('status' => 'approved')
    expect(described_class.fetch_record(other)).to include('status' => 'pending')
  end

  it 'does nothing for no cards' do
    expect { described_class.discard!(action_ids: nil, reason: 'x') }.not_to raise_error
  end

  it 'registers a new pending card with the run that prepared it, and not a card that was acted on' do
    Captain::ReplySuggestion::RunControl.with(request_id: 'r', deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60) do |control|
      card('prepared-by-run')
      card('already-approved', 'approved')

      expect(control.action_ids).to eq(['prepared-by-run'])
    end
  end
end
