require 'rails_helper'
require 'timeout'

RSpec.describe WhatsappWebhookRoute do
  describe '.with_route_identity_lock' do
    it 'serializes mutations for the same route identity' do
      first_acquired = Queue.new
      release_first = Queue.new
      second_started = Queue.new
      second_acquired = Queue.new

      first = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.with_route_identity_lock('123456', '987654', 'dev') do
            first_acquired << true
            release_first.pop
          end
        end
      end
      first_acquired.pop

      second = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          second_started << true
          described_class.with_route_identity_lock('123456', '987654', 'dev') do
            second_acquired << true
          end
        end
      end
      second_started.pop

      expect { Timeout.timeout(0.2) { second_acquired.pop } }.to raise_error(Timeout::Error)
      release_first << true
      expect(Timeout.timeout(2) { second_acquired.pop }).to be(true)

      first.value
      second.value
    ensure
      release_first << true if defined?(release_first)
      first&.join
      second&.join
    end
  end
end
