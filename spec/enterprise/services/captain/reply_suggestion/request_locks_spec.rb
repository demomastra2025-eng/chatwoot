require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::RequestLocks do
  # Redis is not cleared between examples: every example has ids of its own.
  let(:account_id) { SecureRandom.random_number(1_000_000_000) + 1 }
  let(:user_id) { SecureRandom.random_number(1_000_000_000) + 1 }
  let(:conversation_id) { SecureRandom.random_number(1_000_000_000) + 1 }

  describe 'one active run per user and conversation' do
    it 'gives the lock to the first, and tells the second who holds it' do
      expect(described_class.claim_active(account_id, user_id, conversation_id, 'first')).to be_nil
      expect(described_class.claim_active(account_id, user_id, conversation_id, 'second')).to eq('first')
    end

    it 'does not mix users or conversations' do
      described_class.claim_active(account_id, user_id, conversation_id, 'first')

      expect(described_class.claim_active(account_id, user_id + 1, conversation_id, 'other-user')).to be_nil
      expect(described_class.claim_active(account_id, user_id, conversation_id + 1, 'other-conversation')).to be_nil
    end

    it 'is released only by the run that holds it' do
      described_class.claim_active(account_id, user_id, conversation_id, 'first')

      described_class.release_active(account_id, user_id, conversation_id, 'someone-else')
      expect(described_class.claim_active(account_id, user_id, conversation_id, 'second')).to eq('first')

      described_class.release_active(account_id, user_id, conversation_id, 'first')
      expect(described_class.claim_active(account_id, user_id, conversation_id, 'third')).to be_nil
    end
  end

  describe 'the cap of runs of an account' do
    before { allow(Captain::ReplySuggestion).to receive(:max_active_per_account).and_return(2) }

    it 'refuses a run over the cap, and frees a slot when a run ends' do
      expect(described_class.claim_account_slot(account_id, 'a')).to be(true)
      expect(described_class.claim_account_slot(account_id, 'b')).to be(true)
      expect(described_class.claim_account_slot(account_id, 'c')).to be(false)

      described_class.release_account_slot(account_id, 'a')

      expect(described_class.claim_account_slot(account_id, 'c')).to be(true)
    end

    it 'forgets a slot whose time is up (a lost job)' do
      Redis::Alfred.zadd(described_class.account_active_key(account_id), Time.current.to_i - 1, 'lost')
      Redis::Alfred.zadd(described_class.account_active_key(account_id), Time.current.to_i + 100, 'alive')

      expect(described_class.claim_account_slot(account_id, 'new')).to be(true)
      expect(Redis::Alfred.zcard(described_class.account_active_key(account_id))).to eq(2)
    end
  end

  describe '.release!' do
    it 'frees the lock and the slot of a request' do
      record = { 'id' => SecureRandom.uuid, 'account_id' => account_id, 'user_id' => user_id, 'conversation_id' => conversation_id }
      described_class.claim_active(account_id, user_id, conversation_id, record['id'])
      described_class.claim_account_slot(account_id, record['id'])

      described_class.release!(record)

      expect(described_class.claim_active(account_id, user_id, conversation_id, 'next')).to be_nil
      expect(Redis::Alfred.zcard(described_class.account_active_key(account_id))).to eq(0)
    end
  end
end
