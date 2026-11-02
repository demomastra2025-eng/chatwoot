require 'rails_helper'

RSpec.describe Billing::FoundationPreflight do
  self.use_transactional_tests = false

  it 'reports existing quarantine without mutating it or granting access' do
    account = create(:account)
    payer = BillingAccount.create!(name: 'Synthetic payer', standalone_account: account)
    # This synthetic fixture simulates a pre-migration row, not an application adoption path.
    BillingAccount.where(id: payer.id).update_all(foundation_state: 'legacy_pending', standalone_account_id: nil) # rubocop:disable Rails/SkipsModelValidations
    statements = []
    subscription = ActiveSupport::Notifications.subscribe('sql.active_record') { |*, payload| statements << payload[:sql] }

    report = described_class.report

    expect(report).to include(ready: false, codes: ['legacy_mapping_required'])
    expect(report[:legacy_pending]['billing_accounts']).to eq([payer.id])
    expect(report.to_json).not_to include('Synthetic', 'standalone_account_id', 'organization_id')
    expect(statements).to include('SET TRANSACTION READ ONLY')
    expect(statements.grep(/\A\s*(INSERT|UPDATE|DELETE|ALTER|CREATE|DROP|TRUNCATE)\b/i)).to be_empty
    expect(payer.reload.foundation_state).to eq('legacy_pending')
    expect(AccountUser.count).to eq(0)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  it 'lets PostgreSQL refuse a write accidentally added during the diagnostic transaction' do
    diagnostic = instance_double(described_class)
    allow(described_class).to receive(:new).and_return(diagnostic)
    allow(diagnostic).to receive(:report) do
      ActiveRecord::Base.connection.execute("INSERT INTO billing_accounts (name) VALUES ('forbidden')")
    end
    expect { described_class.report }.to raise_error(ActiveRecord::StatementInvalid, /read-only transaction/)
    expect(BillingAccount.count).to eq(0)
  end

  it 'keeps saved terms valid for ordinary updates and preflight after their catalogue names and prices change' do
    payer = BillingAccount.create!(name: 'Synthetic payer', standalone_account: create(:account))
    terms = Billing::PlanSnapshot.compile(tariff: 'text_call', defaults: Accounts::Plans::LIMIT_KEYS.index_with(nil))
    subscription = BillingSubscription.create!(billing_account: payer, **terms)
    config = YAML.safe_load(File.read(Accounts::Plans::CONFIG_PATH))
    config['version'] += 1
    config['tariffs'].delete('text_call')
    config['base']['features'].delete('crm')
    config['tariffs']['voice_ai']['pricing']['monthly_kzt'] += 1
    replacement = Accounts::Plans.new(config, feature_names: Featurable::FEATURE_NAMES - ['crm'])
    allow(Accounts::Plans).to receive(:current).and_return(replacement)

    expect(Billing::PlanSnapshot.valid?(*terms.values_at(:plan_snapshot, :price_snapshot))).to be(false)
    expect { subscription.update!(status: 'canceled') }.not_to raise_error
    expect(described_class.report).to include(ready: true, scope: 'foundation_only')
    expect(subscription.reload.plan_snapshot).to eq(terms[:plan_snapshot])
    expect(subscription.price_snapshot).to eq(terms[:price_snapshot])
  end
end
