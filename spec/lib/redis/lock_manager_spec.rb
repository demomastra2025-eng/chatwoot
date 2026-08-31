require 'rails_helper'

RSpec.describe Redis::LockManager do
  let(:lock_manager) { described_class.new }
  let(:lock_key) { 'test_lock' }

  after do
    # Cleanup: Ensure that the lock key is deleted after each test to avoid interference
    Redis::Alfred.delete(lock_key)
  end

  describe '#lock' do
    it 'acquires a lock and returns true' do
      expect(lock_manager.lock(lock_key)).to be true
      expect(lock_manager.locked?(lock_key)).to be true
    end

    it 'returns false if the lock is already acquired' do
      lock_manager.lock(lock_key)
      expect(lock_manager.lock(lock_key)).to be false
    end

    it 'can acquire a lock again after the timeout' do
      lock_manager.lock(lock_key, 1) # 1-second timeout
      sleep 2
      expect(lock_manager.lock(lock_key)).to be true
    end
  end

  describe '#unlock' do
    it 'releases a lock' do
      lock_manager.lock(lock_key)
      lock_manager.unlock(lock_key)
      expect(lock_manager.locked?(lock_key)).to be false
    end

    it 'does not delete a successor lock after the original lease expires' do
      lock_manager.lock(lock_key)
      Redis::Alfred.set(lock_key, 'successor-token', ex: 1.minute)

      expect(lock_manager.unlock(lock_key)).to be(false)
      expect(Redis::Alfred.get(lock_key)).to eq('successor-token')
    end
  end

  describe '#renew' do
    it 'extends a lease owned by this manager' do
      lock_manager.lock(lock_key, 1)

      expect(lock_manager.renew(lock_key, 1.minute)).to be(true)
      expect(Redis::Alfred.get(lock_key)).to be_present
    end

    it 'does not extend a successor lease' do
      lock_manager.lock(lock_key, 1)
      Redis::Alfred.set(lock_key, 'successor-token', ex: 1.minute)

      expect(lock_manager.renew(lock_key, 1.hour)).to be(false)
      expect(Redis::Alfred.get(lock_key)).to eq('successor-token')
    end
  end

  describe '#locked?' do
    it 'returns true if a key is locked' do
      lock_manager.lock(lock_key)
      expect(lock_manager.locked?(lock_key)).to be true
    end

    it 'returns false if a key is not locked' do
      expect(lock_manager.locked?(lock_key)).to be false
    end
  end
end
