require 'rails_helper'

describe Whatsapp::MessageDedupLock do
  let(:inbox_id) { 42 }
  let(:source_id) { "wamid.test_#{SecureRandom.hex(8)}" }
  let(:other_source_id) { "wamid.other_#{SecureRandom.hex(8)}" }
  let(:lock) { described_class.new(inbox_id: inbox_id, source_id: source_id) }

  after do
    [source_id, other_source_id].each do |id|
      key_pattern = format(Redis::RedisKeys::MESSAGE_SOURCE_KEY, id: "whatsapp:*:#{id}")
      Redis::Alfred.scan_each(match: key_pattern) { |key| Redis::Alfred.delete(key) }
    end
  end

  describe '#acquire!' do
    it 'returns truthy on first acquire' do
      expect(lock.acquire!).to be_truthy
    end

    it 'returns falsy on second acquire for the same source_id' do
      lock.acquire!
      expect(described_class.new(inbox_id: inbox_id, source_id: source_id).acquire!).to be_falsy
    end

    it 'allows different source_ids to acquire independently' do
      lock.acquire!
      other = described_class.new(inbox_id: inbox_id, source_id: other_source_id)
      expect(other.acquire!).to be_truthy
    end

    it 'allows the same source_id to acquire independently for different inboxes' do
      lock.acquire!

      expect(described_class.new(inbox_id: inbox_id + 1, source_id: source_id).acquire!).to be_truthy
    end

    it 'lets exactly one thread win when two race for the same source_id' do
      results = Concurrent::Array.new
      barrier = Concurrent::CyclicBarrier.new(2)

      threads = Array.new(2) do
        Thread.new do
          barrier.wait
          results << described_class.new(inbox_id: inbox_id, source_id: source_id).acquire!
        end
      end

      threads.each(&:join)

      wins = results.count { |r| r }
      expect(wins).to eq(1), "Expected exactly 1 winner but got #{wins}. Results: #{results.inspect}"
    end

    it 'can be acquired again after the owner releases it' do
      lock.acquire!

      expect(lock.release!).to be(true)
      expect(described_class.new(inbox_id: inbox_id, source_id: source_id).acquire!).to be_truthy
    end

    it 'does not release a lock owned by another instance' do
      lock.acquire!
      other = described_class.new(inbox_id: inbox_id, source_id: source_id)

      expect(other.release!).to be(false)
      expect(other.acquire!).to be_falsy
    end
  end
end
