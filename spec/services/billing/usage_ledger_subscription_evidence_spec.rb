require 'rails_helper'

RSpec.describe Billing::UsageLedger do
  include BillingUnitLedgerHelpers

  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:package) { ledger_package(accounts: [account]) }
  let(:at) { Time.utc(2026, 11, 6, 12) }

  def refused_without_writes(inputs, code: nil)
    mutations = []
    listener = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      mutations << payload[:sql] if payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE|TRUNCATE|CREATE|ALTER|DROP)\b/i)
    end
    result = described_class.reconcile!(**inputs)
    expect(result[:status]).to eq(:needs_review)
    expect(result[:code]).to eq(code) if code
    expect(mutations).to be_empty
    result
  ensure
    ActiveSupport::Notifications.unsubscribe(listener) if listener
  end

  def event_inputs
    event = ledger_event(account: account, contact: contact, at: at)
    ledger_inputs(account: account, contact: contact, entries: [[event, package]])
  end

  it 'retains the exact confirmed event witness after cancellation and later renewal fields change' do
    inputs = event_inputs
    expect(described_class.reconcile!(**inputs)[:status]).to eq(:applied)
    projection = Billing::UsageProjection.sole
    confirmed = projection.sources.deep_dup
    package[:subscription].update!(status: 'canceled', current_period_starts_at: Time.utc(2027, 1, 15),
                                   current_period_ends_at: Time.utc(2027, 2, 15))
    allow(Accounts::Plans).to receive(:current).and_raise('historical YAML forbidden')
    expect(described_class.preview(**inputs)[:status]).to eq(:no_op)
    expect { expect(described_class.reconcile!(**inputs)[:status]).to eq(:no_op) }.not_to change(Billing::UsageRevision, :count)
    expect(projection.reload.sources).to eq(confirmed)
  end

  it 'separates the billing-day15 month anchor from each new event cycle before and after renewal' do
    first = ledger_event(account: account, contact: contact, at: at)
    inputs = ledger_inputs(account: account, contact: contact, entries: [[first, package]])
    expect(described_class.reconcile!(**inputs)[:status]).to eq(:applied)
    original = Billing::UsageProjection.sole.sources.fetch(first.id.to_s).deep_dup
    package[:subscription].update!(current_period_starts_at: Time.utc(2026, 11, 15), current_period_ends_at: Time.utc(2026, 12, 15))
    second = ledger_event(account: account, contact: contact, at: Time.utc(2026, 11, 16))
    renewed = ledger_inputs(account: account, contact: contact, entries: [[first, package], [second, package]], version: 1)
    expect(described_class.reconcile!(**renewed)[:status]).to eq(:applied)
    projection = Billing::UsageProjection.sole
    expect(projection.sources.fetch(first.id.to_s)).to eq(original)
    expect(projection.sources.dig(second.id.to_s, 'subscription_evidence', 'cycle_starts_at')).to eq('2026-11-15T00:00:00.000000Z')
    expect(package[:period].anchor_ends_at).to be < second.occurred_at
    package[:subscription].update!(status: 'canceled', current_period_starts_at: Time.utc(2026, 12, 15),
                                   current_period_ends_at: Time.utc(2027, 1, 15))
    expect(described_class.reconcile!(**renewed)[:status]).to eq(:no_op)
    expect(package[:period].reload.dialogs_count).to eq(2)
  end

  it 'accepts a different equal-priced subscription ID only with its own verified event interval' do
    current = package
    current[:subscription].update!(status: 'canceled')
    replacement = BillingSubscription.create!(
      billing_account: current[:payer], status: 'active', created_at: Time.utc(2026, 11, 2),
      current_period_starts_at: Time.utc(2026, 11, 2), current_period_ends_at: Time.utc(2026, 12, 2),
      plan_snapshot: current[:subscription].plan_snapshot, price_snapshot: current[:subscription].price_snapshot
    )
    inputs = event_inputs
    inputs[:provenance].each_value { |proof| proof[:subscription_id] = replacement.id }
    expect(described_class.reconcile!(**inputs)[:status]).to eq(:applied)
    expect(Billing::UsageProjection.sole.sources.values.sole['subscription_id']).to eq(replacement.id)
    expect(current[:period].billing_subscription_id).to eq(current[:subscription].id)
  end

  it 'preserves both exact witnesses through a clinical merge after their subscription is canceled' do
    other = create(:contact, account: account)
    first = ledger_event(account: account, contact: contact, at: at)
    second = ledger_event(account: account, contact: other, at: at + 1.minute)
    target = described_class.reconcile!(**ledger_inputs(account: account, contact: contact, entries: [[first, package]]))
    source = described_class.reconcile!(**ledger_inputs(account: account, contact: other, entries: [[second, package]]))
    witnesses = Billing::UsageProjection.all.each_with_object({}) { |projection, all| all.merge!(projection.sources) }
    package[:subscription].update!(status: 'canceled')
    Accounts::AiUsageEvent.where(id: second.id).update_all(contact_id: contact.id) # rubocop:disable Rails/SkipsModelValidations
    inputs = ledger_inputs(account: account, contact: contact, entries: [[first, package], [second, package]], version: target[:version],
                           merge_from: { source[:projection_id] => source[:version] })
    expect(described_class.reconcile!(**inputs)[:status]).to eq(:applied)
    expect(package[:period].reload.dialogs_count).to eq(1)
    expect(Billing::UsageProjection.find(target[:projection_id]).sources).to eq(witnesses)
    expect(described_class.reconcile!(**inputs)[:status]).to eq(:no_op)
  end

  it 'does not extend a confirmed cycle witness to an unconfirmed late event after cancellation' do
    inputs = event_inputs
    first = Accounts::AiUsageEvent.find(inputs[:event_ids].sole)
    expect(described_class.reconcile!(**inputs)[:status]).to eq(:applied)
    confirmed = Billing::UsageProjection.sole.sources.deep_dup
    package[:subscription].update!(status: 'canceled')
    late = ledger_event(account: account, contact: contact, at: at - 1.minute)
    amended = ledger_inputs(account: account, contact: contact, entries: [[first, package], [late, package]], version: 1)
    refused_without_writes(amended, code: :subscription_interval_unproved)
    expect(Billing::UsageProjection.sole.sources).to eq(confirmed)
    expect(package[:period].reload.dialogs_count).to eq(1)
  end

  it 'refuses a newly observed canceled event even if the same-ID frozen month anchor covers it' do
    inputs = event_inputs
    expect(package[:period].anchor_starts_at).to be <= at
    expect(package[:period].anchor_ends_at).to be > at
    package[:subscription].update!(status: 'canceled')
    expect(refused_without_writes(inputs)[:code]).to eq(:subscription_interval_unproved)
  end

  it 'refuses an unconfirmed old event after renewal even though its same-ID month anchor covers it' do
    inputs = event_inputs
    package[:subscription].update!(current_period_starts_at: Time.utc(2026, 11, 15), current_period_ends_at: Time.utc(2026, 12, 15))
    expect(package[:period].anchor_starts_at).to be <= at
    expect(package[:period].anchor_ends_at).to be > at
    expect(refused_without_writes(inputs)[:code]).to eq(:subscription_interval_unproved)
  end

  it 'refuses an expired active cycle and treats its right endpoint as exclusive' do
    inputs = event_inputs
    package[:subscription].update!(current_period_starts_at: Time.utc(2026, 10, 15), current_period_ends_at: at)
    expect(refused_without_writes(inputs)[:code]).to eq(:subscription_interval_unproved)
    expect(package[:period].reload.dialogs_count).to eq(0)
  end

  it 'refuses each missing cycle endpoint rather than inventing an open-ended contract' do
    inputs = event_inputs
    package[:subscription].update!(current_period_starts_at: nil)
    expect(refused_without_writes(inputs)[:code]).to eq(:subscription_interval_unproved)
    package[:subscription].update!(current_period_starts_at: Time.utc(2026, 10, 15), current_period_ends_at: nil)
    expect(refused_without_writes(inputs)[:code]).to eq(:subscription_interval_unproved)
  end

  it 'refuses a subscription created after the event even if its current interval covers it' do
    inputs = event_inputs
    package[:subscription].update!(created_at: at + 1.second)
    expect(refused_without_writes(inputs)[:code]).to eq(:subscription_interval_unproved)
  end

  it 'refuses an equal-priced but foreign owner interval without postings' do
    inputs = event_inputs
    foreign = ledger_package(accounts: [create(:account)])
    inputs[:provenance].each_value { |proof| proof[:subscription_id] = foreign[:subscription].id }
    expect(refused_without_writes(inputs)[:code]).to eq(:terms_changed)
  end

  it 'quarantines source02293 tuples without evidence instead of grandfathering their month anchor' do
    inputs = event_inputs
    expect(described_class.reconcile!(**inputs)[:status]).to eq(:applied)
    projection = Billing::UsageProjection.sole
    old_sources = projection.sources.transform_values { |source| source.except('subscription_evidence') }
    projection.update_columns(sources: old_sources) # rubocop:disable Rails/SkipsModelValidations
    refused_without_writes(inputs, code: :projection_corrupt)
    expect(projection.reload.sources).to eq(old_sources)
    expect(package[:period].reload.dialogs_count).to eq(1)
  end

  it 'rejects caller-supplied witness keys without accepting them as an internal proof' do
    inputs = event_inputs
    inputs[:provenance].each_value { |proof| proof[:subscription_evidence] = { version: 1 } }
    expect(refused_without_writes(inputs)[:code]).to eq(:provenance_missing)
  end

  it 'rejects a witness copied to another event and ordinary updates to already confirmed evidence' do
    inputs = event_inputs
    described_class.reconcile!(**inputs)
    projection = Billing::UsageProjection.sole
    copied = projection.sources.deep_dup
    copied[(inputs[:event_ids].sole + 1).to_s] = copied.values.sole.deep_dup
    expect { projection.update!(sources: copied) }.to raise_error(ActiveRecord::RecordInvalid, /invalid numeric ledger payload/)
    changed = projection.reload.sources.deep_dup
    changed.values.sole['subscription_evidence']['cycle_ends_at'] = '2027-12-15T00:00:00.000000Z'
    expect { projection.update!(sources: changed) }.to raise_error(ActiveRecord::RecordInvalid, /confirmed source evidence is immutable/)
    expect(described_class.reconcile!(**inputs)[:status]).to eq(:no_op)
  end
end
