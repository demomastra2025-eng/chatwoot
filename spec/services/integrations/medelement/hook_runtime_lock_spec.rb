require 'rails_helper'
require 'timeout'

RSpec.describe Integrations::Medelement::HookRuntimeLock do
  self.use_transactional_tests = false

  it 'requires an open transaction' do
    expect do
      described_class.acquire!(account_id: 17, hook_id: 29)
    end.to raise_error('Medelement hook runtime lock requires an open transaction')
  end

  it 'serializes the same hook identity across database connections' do
    entered = Queue.new
    release_first = Queue.new
    second_started = Queue.new

    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction(requires_new: true) do
          described_class.acquire!(account_id: 17, hook_id: 29)
          entered << :first
          release_first.pop
        end
      end
    end
    expect(Timeout.timeout(2) { entered.pop }).to eq(:first)

    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction(requires_new: true) do
          second_started << true
          described_class.acquire!(account_id: 17, hook_id: 29)
          entered << :second
        end
      end
    end
    Timeout.timeout(2) { second_started.pop }

    expect { Timeout.timeout(0.2) { entered.pop } }.to raise_error(Timeout::Error)
    release_first << true
    expect(Timeout.timeout(2) { entered.pop }).to eq(:second)
    [first, second].each(&:join)
  ensure
    release_first&.push(true) if first&.alive?
    [first, second].compact.each do |thread|
      thread.join(2)
      thread.kill if thread.alive?
    end
  end
end
