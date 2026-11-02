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

  it 'reloads a changed subscription after a real term-row wait instead of accepting its stale pre-lock cycle' do
    account = create(:account)
    contact = create(:contact, account: account)
    package = ledger_package(accounts: [account])
    event = ledger_event(account: account, contact: contact, at: Time.utc(2026, 11, 6))
    inputs = ledger_inputs(account: account, contact: contact, entries: [[event, package]])
    held, release, backend, observed, results = Array.new(5) { Queue.new }
    input = Billing::UsageLedger::Input.new(**inputs)
    allow(Billing::UsageLedger::Input).to receive(:new).with(**inputs).and_return(input)
    allow(input).to receive(:load!).and_wrap_original do |original|
      loaded = original.call
      observed << loaded.subscriptions.fetch(package[:subscription].id).current_period_ends_at
      loaded
    end
    writer = hold_renewal(package[:subscription].id, held, release)
    writer_pid = Timeout.timeout(20) { held.pop }
    ledger = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        backend << connection.select_value('SELECT pg_backend_pid()')
        results << described_class.reconcile!(**inputs)
      end
    end
    expect(Timeout.timeout(20) { observed.pop }).to eq(package[:subscription].current_period_ends_at)
    ledger_pid = Timeout.timeout(20) { backend.pop }
    Timeout.timeout(20) do
      loop do
        break if ActiveRecord::Base.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid=#{Integer(ledger_pid)}") == 'Lock'

        sleep 0.02
      end
    end
    blockers = ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{Integer(ledger_pid)})::text")
    expect(blockers).to include(writer_pid.to_s)
    release << true
    [writer, ledger].each { |thread| Timeout.timeout(25) { thread.value } }
    expect(results.pop).to include(status: :needs_review, code: :subscription_interval_unproved)
    expect([Billing::UsageProjection.count, Billing::UsageRevision.count, package[:period].reload.dialogs_count]).to eq([0, 0, 0])
  ensure
    release << true if release
    [writer, ledger].compact.each { |thread| thread.join(25) }
  end

  def hold_renewal(subscription_id, held, release)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        BillingSubscription.transaction do
          subscription = BillingSubscription.lock.find(subscription_id)
          subscription.update!(current_period_starts_at: Time.utc(2026, 11, 15), current_period_ends_at: Time.utc(2026, 12, 15))
          held << connection.select_value('SELECT pg_backend_pid()')
          release.pop
        end
      end
    end
  end
end
