require 'rails_helper'

RSpec.describe Billing::UsagePeriod do
  include BillingUnitLedgerHelpers

  it 'captures the month-start anchor from a billing-day15 cycle rather than demanding whole-month renewal coverage' do
    package = ledger_package(accounts: [create(:account)])
    period = package[:period]
    expect(period.starts_at).to eq(Time.new(2026, 11, 1, 0, 0, 0, '+05:00'))
    expect(period.anchor_starts_at.in_time_zone(Billing::ALMATY_TIMEZONE).day).to eq(15)
    expect(period.anchor_ends_at).to be < period.ends_at
    package[:subscription].update!(current_period_starts_at: Time.utc(2026, 11, 15), current_period_ends_at: Time.utc(2026, 12, 15))
    expect(period.reload).to be_valid
    expect { period.update!(month: Date.new(2026, 12, 1)) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
  end

  it 'refuses an unproved past anchor and a subscription created after that anchor' do
    package = ledger_package(accounts: [create(:account)])
    attributes = package[:period].attributes.slice('billing_account_id', 'billing_subscription_id', 'plan_snapshot', 'price_snapshot')
    old = described_class.new(attributes.merge(month: Date.new(2026, 10, 1)))
    expect(old).not_to be_valid
    expect(old.errors.full_messages.join).to include('unproved historical terms')
    package[:subscription].update!(status: 'canceled')
    replacement = BillingSubscription.create!(billing_account: package[:payer], created_at: Time.utc(2026, 11, 2),
                                              current_period_starts_at: Time.utc(2026, 10, 15), current_period_ends_at: Time.utc(2026, 11, 15),
                                              plan_snapshot: attributes['plan_snapshot'], price_snapshot: attributes['price_snapshot'])
    month = BillingUnitLedgerHelpers::LEDGER_MONTH
    expect(described_class.new(attributes.merge(month: month, billing_subscription_id: replacement.id))).not_to be_valid
  end

  it 'never reinterprets proven immutable snapshots through the current catalogue' do
    period = ledger_package(accounts: [create(:account)])[:period]
    allow(Accounts::Plans).to receive(:current).and_raise('current YAML must not be read')
    expect(period.reload).to be_valid
    period.price_snapshot['pricing']['monthly_kzt'] += 1
    expect { period.save! }.to raise_error(ActiveRecord::ReadonlyAttributeError)
  end
end
