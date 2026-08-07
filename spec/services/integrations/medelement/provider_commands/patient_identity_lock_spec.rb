require 'rails_helper'
require 'timeout'

RSpec.describe Integrations::Medelement::ProviderCommands::PatientIdentityLock do
  describe '#synchronize' do
    it 'holds and releases one PostgreSQL advisory lock around the identity operation' do
      connection = instance_double(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
      allow(connection).to receive(:quote).and_return('123')
      expect(connection).to receive(:execute).with('SELECT pg_advisory_lock(123)').ordered
      expect(connection).to receive(:execute).with('SELECT pg_advisory_unlock(123)').ordered
      allow(ActiveRecord::Base.connection_pool).to receive(:with_connection).and_yield(connection)

      result = described_class.new(account_id: 1, iin: '940720300129').synchronize { :resolved }

      expect(result).to eq(:resolved)
    end

    it 'releases the advisory lock when identity resolution raises' do
      connection = instance_double(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
      allow(connection).to receive(:quote).and_return('123')
      expect(connection).to receive(:execute).with('SELECT pg_advisory_lock(123)').ordered
      expect(connection).to receive(:execute).with('SELECT pg_advisory_unlock(123)').ordered
      allow(ActiveRecord::Base.connection_pool).to receive(:with_connection).and_yield(connection)

      expect do
        described_class.new(account_id: 1, iin: '940720300129').synchronize { raise 'failure' }
      end.to raise_error('failure')
    end

    it 'rejects an invalid IIN before acquiring a connection' do
      expect(ActiveRecord::Base.connection_pool).not_to receive(:with_connection)

      expect do
        described_class.new(account_id: 1, iin: '123')
      end.to raise_error(ArgumentError, 'valid IIN is required for patient identity lock')
    end

    it 'serializes concurrent workers for the same account and IIN' do
      entered = Queue.new
      release_first = Queue.new
      second_started = Queue.new
      lock_attributes = { account_id: 17, iin: '940720300129' }

      first = Thread.new do
        described_class.new(**lock_attributes).synchronize do
          entered << :first
          release_first.pop
        end
      end
      expect(Timeout.timeout(2) { entered.pop }).to eq(:first)

      second = Thread.new do
        second_started << true
        described_class.new(**lock_attributes).synchronize { entered << :second }
      end
      Timeout.timeout(2) { second_started.pop }

      expect { Timeout.timeout(0.2) { entered.pop } }.to raise_error(Timeout::Error)
      release_first << true
      expect(Timeout.timeout(2) { entered.pop }).to eq(:second)
      [first, second].each(&:join)
      expect(described_class.send(:local_locks)).to be_empty
    ensure
      release_first&.push(true) if first&.alive?
      [first, second].compact.each do |thread|
        thread.join(2)
        thread.kill if thread.alive?
      end
    end
  end
end
