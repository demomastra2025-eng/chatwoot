require 'rails_helper'

RSpec.describe Billing::UsageLedger do
  include BillingUnitLedgerHelpers

  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:package) { ledger_package(accounts: [account]) }
  let(:at) { Time.utc(2026, 11, 5, 8) }

  it 'previews without writes and records a numeric projection once on explicit reconciliation' do
    event = ledger_event(account: account, contact: contact, at: at)
    inputs = ledger_inputs(account: account, contact: contact, entries: [[event, package]])
    expect { expect(described_class.preview(**inputs)[:status]).to eq(:ready) }.not_to change(Billing::UsageProjection, :count)
    result = described_class.reconcile!(**inputs)
    expect(result[:status]).to eq(:applied)
    expect(package[:period].reload.dialogs_count).to eq(1)
    expect(described_class.reconcile!(**inputs)[:status]).to eq(:no_op)
    expect(Billing::UsageRevision.count).to eq(1)
    expect(Billing::UsageProjection.first.window_sources).to eq([[event.id, package[:period].id]])
  end

  it 'moves the first-window allocation A to B and back to A with unchanged canonical account totals' do
    first_boundary = Time.utc(2026, 11, 5, 10)
    second_boundary = first_boundary + 1.hour
    first = ledger_package(accounts: [account], to: first_boundary)
    middle = ledger_package(accounts: [account], from: first_boundary, to: second_boundary)
    account.update!(organization: first[:payer].organization)
    last_workspace = BillingAccountWorkspace.create!(account: account, billing_account: first[:payer], starts_at: second_boundary)
    last = first.merge(workspaces: { account.id => last_workspace })
    e1 = ledger_event(account: account, contact: contact, at: second_boundary + 15.minutes)
    service = Accounts::MonthlyAiUsageService.new(account)
    service.reconcile_ai_dialogs!(contact)
    expect(described_class.reconcile!(**ledger_inputs(account: account, contact: contact, entries: [[e1, last]]))[:status]).to eq(:applied)
    e2 = ledger_event(account: account, contact: contact, at: first_boundary + 30.minutes)
    service.reconcile_ai_dialogs!(contact)
    result = described_class.reconcile!(**ledger_inputs(account: account, contact: contact, entries: [[e1, last], [e2, middle]], version: 1))
    expect(result[:deltas]).to eq(first[:period].id => { 'dialogs' => -1, 'seconds' => 0 }, middle[:period].id => { 'dialogs' => 1, 'seconds' => 0 })
    e3 = ledger_event(account: account, contact: contact, at: first_boundary - 15.minutes)
    service.reconcile_ai_dialogs!(contact)
    result = described_class.reconcile!(**ledger_inputs(account: account, contact: contact, entries: [[e1, last], [e2, middle], [e3, first]],
                                                        version: 2))
    expect(result[:status]).to eq(:applied)
    expect([first[:period].reload.dialogs_count, middle[:period].reload.dialogs_count]).to eq([1, 0])
    expect(Accounts::MonthlyAiUsageService.new(account.reload).ai_dialogs_consumed(at: at)).to eq(1)
  end

  it 'owns a cross-month window in the first reply month in Almaty' do
    current = package
    october = ledger_period(payer: current[:payer], subscription: current[:subscription], month: Date.new(2026, 10, 1))
    # The October month anchor remains frozen; these new events need the actual Oct15-Nov15 cycle.
    current[:subscription].update!(current_period_starts_at: current[:period].anchor_starts_at,
                                   current_period_ends_at: current[:period].anchor_ends_at)
    old = current.merge(period: october)
    e1 = ledger_event(account: account, contact: contact, at: Time.utc(2026, 10, 31, 18, 59))
    e2 = ledger_event(account: account, contact: contact, at: Time.utc(2026, 10, 31, 19, 1))
    result = described_class.reconcile!(**ledger_inputs(account: account, contact: contact, entries: [[e1, old], [e2, current]]))
    expect(result[:status]).to eq(:applied)
    expect([october.reload.dialogs_count, current[:period].reload.dialogs_count]).to eq([1, 0])
  end

  it 'opens the 21st reply as a new window using the same timeline' do
    entries = Array.new(21) { |index| [ledger_event(account: account, contact: contact, at: at + index.seconds), package] }
    expect(described_class.reconcile!(**ledger_inputs(account: account, contact: contact, entries: entries))[:status]).to eq(:applied)
    expect(package[:period].reload.dialogs_count).to eq(2)
  end

  it 'rejects a stale writer, captures a zero-unit source change, and replays without another financial revision' do
    first = ledger_event(account: account, contact: contact, at: at)
    described_class.reconcile!(**ledger_inputs(account: account, contact: contact, entries: [[first, package]]))
    second = ledger_event(account: account, contact: contact, at: at + 1.minute)
    inputs = ledger_inputs(account: account, contact: contact, entries: [[first, package], [second, package]])
    expect(described_class.reconcile!(**inputs)[:status]).to eq(:conflict)
    expect(Billing::UsageProjection.first.version).to eq(1)
    inputs[:expected_version] = 1
    expect(described_class.reconcile!(**inputs)[:version]).to eq(2)
    expect(described_class.reconcile!(**inputs)[:status]).to eq(:no_op)
    expect(Billing::UsageRevision.count).to eq(1)
  end

  it 'takes real SQL locks in identity-contact-account-payer-subscription-source-projection-period order' do
    first = ledger_event(account: account, contact: contact, at: at)
    described_class.reconcile!(**ledger_inputs(account: account, contact: contact, entries: [[first, package]]))
    second = ledger_event(account: account, contact: contact, at: at + 1.minute)
    statements = []
    listener = ActiveSupport::Notifications.subscribe('sql.active_record') { |*, payload| statements << payload[:sql] }
    described_class.reconcile!(**ledger_inputs(account: account, contact: contact, entries: [[first, package], [second, package]], version: 1))
    indices = [statements.index { |sql| sql.include?('pg_advisory_xact_lock') }]
    %w[contacts accounts billing_accounts billing_subscriptions billing_account_workspaces account_ai_usage_events billing_usage_projections
       billing_usage_periods].each do |table|
      indices << statements.index { |sql| sql.include?("FROM \"#{table}\"") && sql.include?('FOR ') }
    end
    expect(indices).to all(be_a(Integer))
    expect(indices).to eq(indices.sort)
  ensure
    ActiveSupport::Notifications.unsubscribe(listener) if listener
  end

  it 'sums canonical call seconds across branches before one minute rounding' do
    other = create(:account)
    shared = ledger_package(accounts: [account, other])
    [[account, 30], [other, 30]].each do |branch, seconds|
      event = ledger_event(account: branch, seconds: seconds, at: at)
      expect(described_class.reconcile!(**ledger_inputs(account: branch, entries: [[event, shared]]))[:status]).to eq(:applied)
    end
    expect([shared[:period].reload.call_seconds, shared[:period].call_minutes]).to eq([60, 1])
    expect(defined?(CallUsageEvent)).to be_nil
  end

  it 'refuses subsets, disappeared sources and deleted clinical identities without reversing old units' do
    e1 = ledger_event(account: account, contact: contact, at: at)
    e2 = ledger_event(account: account, contact: contact, at: at + 1.minute)
    inputs = ledger_inputs(account: account, contact: contact, entries: [[e1, package], [e2, package]])
    described_class.reconcile!(**inputs)
    subset = inputs.merge(event_ids: [e1.id], provenance: inputs[:provenance].slice(e1.id), expected_version: 1)
    expect(described_class.reconcile!(**subset)[:code]).to eq(:incomplete_source)
    Accounts::AiUsageEvent.where(id: e2.id).delete_all
    expect(described_class.reconcile!(**inputs)[:code]).to eq(:source_missing)
    Contact.where(id: contact.id).delete_all
    expect(described_class.reconcile!(**subset)[:code]).to eq(:clinical_source_missing)
    expect(package[:period].reload.dialogs_count).to eq(1)
    expect(Billing::UsageProjection.count).to eq(1)
  end

  it 'requires a verified empty legacy baseline and complete explicit provenance/periods' do
    event = ledger_event(account: account, contact: contact, at: at)
    inputs = ledger_inputs(account: account, contact: contact, entries: [[event, package]])
    expect(described_class.reconcile!(**inputs, baseline: nil)[:code]).to eq(:legacy_baseline_missing)
    expect(described_class.reconcile!(**inputs, provenance: {})[:code]).to eq(:provenance_missing)
    broken = inputs.deep_dup
    broken[:provenance][event.id][:period_id] = 999_999_999
    expect(described_class.reconcile!(**broken)[:code]).to eq(:historical_terms_missing)
    Accounts::AiDialogState.create!(account: account, contact: contact, state: { 'legacy_seeds' => [{ 'at' => at.iso8601, 'count' => 1 }] })
    expect(described_class.reconcile!(**inputs)[:code]).to eq(:legacy_baseline_missing)
    expect(Billing::UsageRevision.count).to eq(0)
  end

  it 'keeps observed month-start terms after renewal and refuses an actual different midmonth snapshot' do
    original = package
    original[:subscription].update!(current_period_starts_at: Time.utc(2026, 11, 15), current_period_ends_at: Time.utc(2026, 12, 15))
    event = ledger_event(account: account, contact: contact, at: Time.utc(2026, 11, 16))
    inputs = ledger_inputs(account: account, contact: contact, entries: [[event, original]])
    expect(described_class.preview(**inputs)[:status]).to eq(:ready)
    original[:subscription].update!(status: 'canceled')
    terms = Billing::PlanSnapshot.compile(tariff: 'voice_ai', defaults: Accounts::Plans::LIMIT_KEYS.index_with(nil))
    replacement = BillingSubscription.create!(billing_account: original[:payer], status: 'active', created_at: Time.utc(2026, 11, 10), **terms)
    inputs[:provenance][event.id][:subscription_id] = replacement.id
    expect(described_class.reconcile!(**inputs)[:code]).to eq(:terms_changed)
    expect(Billing::UsageRevision.count).to eq(0)
  end

  it 'rejects extra private fields without copying them into ledger results or snapshots' do
    event = ledger_event(account: account, contact: contact, at: at)
    inputs = ledger_inputs(account: account, contact: contact, entries: [[event, package]])
    bad = inputs.deep_dup
    bad[:provenance][event.id][:raw_text] = 'PRIVATE_PATIENT_DATA_SENTINEL'
    result = described_class.reconcile!(**bad)
    expect(result[:code]).to eq(:provenance_missing)
    expect(result.to_json).not_to include('PRIVATE_PATIENT_DATA_SENTINEL')
    described_class.reconcile!(**inputs)
    expect(Billing::UsageProjection.first.sources.to_json).not_to include('name', 'phone', 'raw_text', 'PRIVATE_PATIENT_DATA_SENTINEL')
  end

  it 'merges both old financial allocations, then retains their history after Contact deletion' do
    source = create(:contact, account: account)
    e1 = ledger_event(account: account, contact: contact, at: at)
    e2 = ledger_event(account: account, contact: source, at: at + 1.minute)
    target_result = described_class.reconcile!(**ledger_inputs(account: account, contact: contact, entries: [[e1, package]]))
    source_result = described_class.reconcile!(**ledger_inputs(account: account, contact: source, entries: [[e2, package]]))
    # Simulate the canonical merge's clinical reassignment without installing a runtime ledger hook.
    Accounts::AiUsageEvent.where(id: e2.id).update_all(contact_id: contact.id) # rubocop:disable Rails/SkipsModelValidations
    inputs = ledger_inputs(account: account, contact: contact, entries: [[e1, package], [e2, package]], version: target_result[:version],
                           merge_from: { source_result[:projection_id] => source_result[:version] })
    expect(described_class.reconcile!(**inputs)[:status]).to eq(:applied)
    expect(package[:period].reload.dialogs_count).to eq(1)
    expect(Billing::UsageRevision.order(:id).last.dialogs_delta).to eq(-1)
    expect(described_class.reconcile!(**inputs)[:status]).to eq(:no_op)
    Contact.where(id: source.id).delete_all
    expect(Billing::UsageProjection.count).to eq(2)
  end

  it 'rolls back source, old state/cache and revisions together, then retries without a double unit' do
    current = package
    conversation = create(:conversation, account: account, contact: contact)
    write = lambda do
      Account.transaction do
        Contacts::PhoneIdentityLock.acquire!(account_id: account.id)
        contact.lock!
        Account.lock('FOR NO KEY UPDATE').find(account.id)
        Accounts::MonthlyAiUsageService.new(account).record_ai_dialog_reply!(conversation, message_id: 91_001, at: at)
        event = Accounts::AiUsageEvent.find_by!(account_id: account.id, event_key: 'message:91001')
        described_class.reconcile!(**ledger_inputs(account: account, contact: contact, entries: [[event, current]]))
      end
    end
    allow(Billing::UsageRevision).to receive(:create!).and_raise('synthetic ledger failure')
    expect { write.call }.to raise_error('synthetic ledger failure')
    expect([Accounts::AiUsageEvent.count, Accounts::AiDialogState.count, Billing::UsageProjection.count]).to eq([0, 0, 0])
    expect(current[:period].reload.dialogs_count).to eq(0)
    allow(Billing::UsageRevision).to receive(:create!).and_call_original
    expect(write.call[:status]).to eq(:applied)
    expect(current[:period].reload.dialogs_count).to eq(1)
  end

  it 'keeps revision history append-only and PostgreSQL rejects negative balances' do
    event = ledger_event(account: account, contact: contact, at: at)
    described_class.reconcile!(**ledger_inputs(account: account, contact: contact, entries: [[event, package]]))
    expect { Billing::UsageRevision.first.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect do
      Billing::UsagePeriod.transaction(requires_new: true) do
        ActiveRecord::Base.connection.execute("UPDATE billing_usage_periods SET dialogs_count=-1 WHERE id=#{Integer(package[:period].id)}")
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /chk_billing_usage_period_units/)
    expect(package[:period].reload.dialogs_count).to eq(1)
  end

  it 'rolls back a late financial refusal to its savepoint even if an outer caller commits' do
    other = create(:contact, account: account)
    first = ledger_event(account: account, contact: contact, at: at)
    second = ledger_event(account: account, contact: other, at: at + 1.minute)
    target = described_class.reconcile!(**ledger_inputs(account: account, contact: contact, entries: [[first, package]]))
    source = described_class.reconcile!(**ledger_inputs(account: account, contact: other, entries: [[second, package]]))
    # Simulate an inconsistent pre-existing balance and an explicit clinical merge; the ledger must refuse atomically.
    package[:period].reload.update!(dialogs_count: 0)
    Accounts::AiUsageEvent.where(id: second.id).update_all(contact_id: contact.id) # rubocop:disable Rails/SkipsModelValidations
    inputs = ledger_inputs(account: account, contact: contact, entries: [[first, package], [second, package]], version: target[:version],
                           merge_from: { source[:projection_id] => source[:version] })
    result = Account.transaction { described_class.reconcile!(**inputs) }
    expect(result[:code]).to eq(:negative_balance)
    expect(Billing::UsageProjection.find(target[:projection_id]).version).to eq(1)
    expect(Billing::UsageProjection.find(source[:projection_id])).not_to be_retired
    expect(Billing::UsageRevision.count).to eq(2)
  end
end
