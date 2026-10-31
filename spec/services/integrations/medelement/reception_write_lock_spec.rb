require 'rails_helper'
require 'timeout'

RSpec.describe Integrations::Medelement::ReceptionWriteLock do
  self.use_transactional_tests = false

  let(:account_id) { SecureRandom.random_number(2**32) + 1 }

  def with_connection(errors, &)
    ActiveRecord::Base.connection_pool.with_connection(&)
  rescue StandardError => e
    errors << e
  end

  it 'serializes full and delta writes for one account while another account can proceed' do
    acquired = Queue.new
    release = Queue.new
    entered = Queue.new
    errors = Queue.new
    key = account_id
    full = Thread.new do
      with_connection(errors) do
        described_class.with_account(account_id: key) do
          acquired << true
          release.pop
        end
      end
    end
    Timeout.timeout(3) { acquired.pop }
    delta = Thread.new do
      with_connection(errors) { described_class.with_account(account_id: key) { entered << true } }
    end

    expect { Timeout.timeout(0.2) { entered.pop } }.to raise_error(Timeout::Error)
    expect(described_class.with_account(account_id: key + 1) { :independent }).to eq(:independent)
    release << true
    expect(Timeout.timeout(3) { entered.pop }).to be(true)
    [full, delta].each { |thread| expect(thread.join(3)).to eq(thread) }
    raise errors.pop unless errors.empty?
  ensure
    release << true if full&.alive?
    full&.join(3)
    delta&.join(3)
  end

  it 'releases the account lock on rollback so the next writer is not stranded' do
    key = account_id
    expect do
      described_class.with_account(account_id: key) { raise 'write rolled back' }
    end.to raise_error('write rolled back')
    entered = Queue.new
    errors = Queue.new
    writer = Thread.new do
      with_connection(errors) { described_class.with_account(account_id: key) { entered << true } }
    end

    expect(Timeout.timeout(3) { entered.pop }).to be(true)
    expect(writer.join(3)).to eq(writer)
    raise errors.pop unless errors.empty?
  ensure
    writer&.join(3)
  end
end
