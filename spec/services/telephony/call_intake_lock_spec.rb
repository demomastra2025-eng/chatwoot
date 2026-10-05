require 'rails_helper'

RSpec.describe Telephony::CallIntakeLock do
  # The waiting test needs two real connections; the spec writes no rows.
  self.use_transactional_tests = false

  describe '.lock_id' do
    it 'is a bigint, as pg_advisory_xact_lock wants it' do
      expect(described_class.lock_id(1, '+70000000001')).to be_between(-(2**63), (2**63) - 1)
    end

    it 'differs between accounts and between callers' do
      expect(described_class.lock_id(1, '+70000000001')).not_to eq(described_class.lock_id(2, '+70000000001'))
      expect(described_class.lock_id(1, '+70000000001')).not_to eq(described_class.lock_id(1, '+70000000002'))
    end

    it 'is the lock Voice::InboundCallBuilder takes first, so taking it earlier cannot invert the lock order' do
      number = '+70000000001'
      normalized = Contacts::PhoneNumberNormalizer.normalize(number) ||
                   Contacts::PhoneNumberNormalizer.normalize(number, default_country: 'KZ') ||
                   number
      identity = ['voice-contact', 1, normalized].join(':')

      expect(described_class.lock_id(1, number)).to eq(Digest::SHA256.digest(identity).unpack1('q>'))
    end
  end

  describe '.acquire!' do
    it 'does nothing without a caller number' do
      expect { described_class.acquire!(account_id: 1, phone_number: nil) }.not_to raise_error
    end

    it 'makes a concurrent leg of the same call wait until the transaction ends' do
      holder_ready = Queue.new
      release_holder = Queue.new
      holder = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.transaction do
            described_class.acquire!(account_id: 7, phone_number: '+70000000001')
            holder_ready << true
            release_holder.pop
          end
        end
      end
      holder_ready.pop

      same_caller = ActiveRecord::Base.connection.select_value(
        "SELECT pg_try_advisory_xact_lock(#{described_class.lock_id(7, '+70000000001')})"
      )
      other_caller = ActiveRecord::Base.connection.select_value(
        "SELECT pg_try_advisory_xact_lock(#{described_class.lock_id(7, '+70000000002')})"
      )
      release_holder << true
      holder.join

      expect(same_caller).to be(false)
      expect(other_caller).to be(true)
    end
  end
end
