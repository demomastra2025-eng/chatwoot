require 'rails_helper'

RSpec.describe OnlineStatusTracker do
  describe '.with_presence_cache' do
    let(:account_id) { 900_001 }

    it 'batches unique IDs, preserves nil/offline semantics and avoids subsequent single reads' do
      described_class.update_presence(account_id, 'Contact', 1)
      Redis::Alfred.zadd(described_class.presence_key(account_id, 'Contact'), 1, 2)
      Redis::Alfred.delete(described_class.presence_key(account_id, 'User'))
      described_class.with_presence_cache do
        expect(Redis::Alfred).to receive(:zscores).with(described_class.presence_key(account_id, 'Contact'), %w[1 2 3]).once.and_call_original
        described_class.preload_presence(account_id, 'Contact', [1, 1, 2, 3])
        expect(Redis::Alfred).not_to receive(:zscore)
        expect(described_class.get_presence(account_id, 'Contact', 1)).to be(true)
        expect(described_class.get_presence(account_id, 'Contact', '2')).to be(false)
        expect(described_class.get_presence(account_id, 'Contact', 3)).to be_nil
      end
      expect(described_class.presence_cache).to be_nil
    end

    it 'does not share cached presence across accounts or object types' do
      allow(Redis::Alfred).to receive(:zscore).and_return(nil)
      described_class.with_presence_cache do
        described_class.get_presence(account_id, 'Contact', 1)
        described_class.get_presence(account_id + 1, 'Contact', 1)
        described_class.get_presence(account_id, 'User', 1)
        described_class.get_presence(account_id, 'Contact', 1)
      end
      expect(Redis::Alfred).to have_received(:zscore).exactly(3).times
    end

    it 'cleans up on exceptions and restores enclosing snapshots' do
      expect do
        described_class.with_presence_cache do
          outer = described_class.presence_cache
          described_class.with_presence_cache { expect(described_class.presence_cache).not_to equal(outer) }
          expect(described_class.presence_cache).to equal(outer)
          raise 'render failure'
        end
      end.to raise_error('render failure')
      expect(described_class.presence_cache).to be_nil
    end

    it 'does not retain values between requests and invalidates updated presence' do
      Redis::Alfred.delete(described_class.presence_key(account_id, 'Contact'))
      described_class.with_presence_cache do
        expect(described_class.get_presence(account_id, 'Contact', 1)).to be_nil
        described_class.update_presence(account_id, 'Contact', 1)
        expect(described_class.get_presence(account_id, 'Contact', 1)).to be(true)
      end
      Redis::Alfred.delete(described_class.presence_key(account_id, 'Contact'))
      described_class.with_presence_cache do
        expect(described_class.get_presence(account_id, 'Contact', 1)).to be_nil
      end
    end
  end
end
