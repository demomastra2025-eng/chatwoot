require 'rails_helper'

RSpec.describe Billing::UsageLedger do
  include BillingUnitLedgerHelpers
  self.use_transactional_tests = false

  it 'serializes two real branch writers at the common payer and preserves both period revisions' do
    accounts = create_list(:account, 2)
    package = ledger_package(accounts: accounts)
    inputs = accounts.map do |account|
      contact = create(:contact, account: account)
      event = ledger_event(account: account, contact: contact, at: Time.utc(2026, 11, 5))
      ledger_inputs(account: account, contact: contact, entries: [[event, package]])
    end
    entered, release, backend, results = Array.new(4) { Queue.new }
    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Account.transaction do
          results << described_class.reconcile!(**inputs.first)
          entered << true
          release.pop
        end
      end
    end
    Timeout.timeout(20) { entered.pop }
    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        backend << connection.select_value('SELECT pg_backend_pid()')
        results << described_class.reconcile!(**inputs.last)
      end
    end
    pid = Timeout.timeout(20) { backend.pop }
    Timeout.timeout(20) do
      loop do
        break if ActiveRecord::Base.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid=#{Integer(pid)}") == 'Lock'

        sleep 0.02
      end
    end
    release << true
    [first, second].each { |thread| Timeout.timeout(25) { thread.value } }
    expect([results.pop[:status], results.pop[:status]]).to eq([:applied, :applied])
    expect(package[:period].reload.attributes.slice('dialogs_count', 'revision')).to eq('dialogs_count' => 2, 'revision' => 2)
    expect(Billing::UsageRevision.order(:revision).pluck(:revision, :dialogs_delta)).to eq([[1, 1], [2, 1]])
  ensure
    release << true if release
    [first, second].compact.each { |thread| thread.join(25) }
  end
end
