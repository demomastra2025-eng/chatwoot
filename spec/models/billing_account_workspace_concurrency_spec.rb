require 'rails_helper'

# Insert directly so the oracle tests the SQL exclusion across payer IDs independently of create-only ownership validation.
# rubocop:disable Rails/SkipsModelValidations

RSpec.describe BillingAccountWorkspace do
  self.use_transactional_tests = false

  it 'rejects one of two overlapping histories committed concurrently by different payers' do
    account = create(:account)
    payers = Array.new(2) { BillingAccount.create!(name: 'Synthetic payer', organization: create(:organization)) }
    inserted = Queue.new
    release = Queue.new
    pid = Queue.new
    outcomes = Queue.new
    times = { starts_at: Time.utc(2026, 11, 1), detached_at: Time.utc(2026, 11, 2), status: 'detached' }
    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.transaction do
          described_class.insert_all!([times.merge(billing_account_id: payers.first.id, account_id: account.id)])
          inserted << true
          release.pop
        end
      end
    end
    Timeout.timeout(15) { inserted.pop }
    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        pid << connection.select_value('SELECT pg_backend_pid()')
        described_class.insert_all!([times.merge(billing_account_id: payers.last.id, account_id: account.id)])
        outcomes << 'unexpected_success'
      rescue ActiveRecord::StatementInvalid => e
        outcomes << e.message
      end
    end
    backend = Timeout.timeout(15) { pid.pop }
    Timeout.timeout(15) do
      loop do
        waiting = ActiveRecord::Base.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(backend)}")
        break if waiting == 'Lock'

        sleep 0.02
      end
    end
    release << true
    [first, second].each { |thread| Timeout.timeout(20) { thread.value } }

    expect(outcomes.pop).to include('excl_billing_workspace_intervals')
    expect(described_class.count).to eq(1)
  ensure
    release << true if release
    [first, second].compact.each { |thread| thread.join(20) }
  end
end
# rubocop:enable Rails/SkipsModelValidations
