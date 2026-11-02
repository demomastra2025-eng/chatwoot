require 'rails_helper'

# Deliberately bypass model validations to exercise PostgreSQL constraints and synthetic legacy quarantine.
# rubocop:disable Rails/SkipsModelValidations

RSpec.describe BillingAccount do
  let(:account) { create(:account) }
  let(:payer) { described_class.create!(name: 'Synthetic payer', standalone_account: account) }
  let(:snapshots) { Billing::PlanSnapshot.compile(tariff: 'text_call', defaults: Accounts::Plans::LIMIT_KEYS.index_with(nil)) }

  it 'requires exactly one explicit owner and does not add any user memberships' do
    expect(described_class.new(name: 'Missing owner')).not_to be_valid
    expect(described_class.new(name: 'Two owners', organization: build(:organization), standalone_account: account)).not_to be_valid
    expect { payer }.not_to change(AccountUser, :count)
    expect { payer.update!(standalone_account_id: account.id + 1) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
  end

  it 'rejects a new legacy quarantine record; pre-existing quarantine remains read-only' do
    expect(described_class.new(name: 'Fake legacy', foundation_state: 'legacy_pending')).not_to be_valid
    payer.update_column(:status, 'closed')
    described_class.where(id: payer.id).update_all(foundation_state: 'legacy_pending', standalone_account_id: nil)

    expect { payer.reload.update!(name: 'Adopt silently') }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect(payer.foundation_state).to eq('legacy_pending')
  end

  it 'rejects owner XOR and owner FK violations in SQL and restricts destruction of the owning account' do
    payer
    expect do
      described_class.transaction(requires_new: true) { described_class.where(id: payer.id).update_all(organization_id: create(:organization).id) }
    end.to raise_error(ActiveRecord::StatementInvalid, /chk_billing_accounts_explicit_owner/)
    expect do
      described_class.transaction(requires_new: true) { described_class.where(id: payer.id).update_all(standalone_account_id: -999) }
    end.to raise_error(ActiveRecord::InvalidForeignKey)
    expect do
      Account.transaction(requires_new: true) { Account.where(id: account.id).delete_all }
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it 'rejects a foreign standalone workspace and preserves saved org history after relinking' do
    foreign = create(:account)
    expect(BillingAccountWorkspace.new(billing_account: payer, account: foreign, starts_at: Time.current)).not_to be_valid
    organization = create(:organization)
    account.update!(organization: organization)
    org_payer = described_class.create!(name: 'Synthetic network', organization: organization)
    history = BillingAccountWorkspace.create!(billing_account: org_payer, account: account, starts_at: 1.day.ago)
    account.update!(organization: create(:organization))
    expect { history.update!(status: 'detached', detached_at: Time.current) }.not_to raise_error
    expect(history.billing_account_id).to eq(org_payer.id)
  end

  it 'stores one entitling subscription, preserves monetary terms, and rejects incomplete snapshots' do
    subscription = BillingSubscription.create!(billing_account: payer, status: 'active', **snapshots)
    original = subscription.plan_snapshot.deep_dup
    expect { subscription.update!(plan_snapshot: original.merge('tariff' => 'voice_ai')) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect { subscription.update_columns(price_snapshot: {}) }.to raise_error(ActiveRecord::ActiveRecordError)
    expect(subscription.reload.plan_snapshot).to eq(original)
    subscription.plan_snapshot['limits']['agents'] = 999
    expect { subscription.save! }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect(BillingSubscription.new(billing_account: payer)).not_to be_valid
    expect do
      BillingSubscription.transaction(requires_new: true) { BillingSubscription.create!(billing_account: payer, status: 'trialing', **snapshots) }
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'rejects actual ready subscription creates with unknown tariff, modules or features' do
    changes = [
      ->(terms) { terms[:plan_snapshot]['tariff'] = terms[:price_snapshot]['tariff'] = 'invented_tariff' },
      ->(terms) { terms[:plan_snapshot]['modules'] = ['invented_module'] },
      ->(terms) { terms[:plan_snapshot]['features'] = ['invented_feature'] }
    ]
    changes.each do |change|
      terms = snapshots.deep_dup
      change.call(terms)
      expect { BillingSubscription.create!(billing_account: payer, **terms) }.to raise_error(ActiveRecord::RecordInvalid, /complete immutable/)
    end
    expect(BillingSubscription.count).to eq(0)
  end

  it 'rejects actual creates with contradictory sources or an invented unlimited sentinel' do
    changes = [
      ['custom', nil], ['plan', nil], ['unlimited', Accounts::Plans.unlimited_value('agents') + 1]
    ]
    changes.each do |source, value|
      terms = snapshots.deep_dup
      terms[:plan_snapshot]['limits']['agents'] = value
      terms[:plan_snapshot]['limit_sources']['agents'] = source
      expect { BillingSubscription.create!(billing_account: payer, **terms) }.to raise_error(ActiveRecord::RecordInvalid, /complete immutable/)
    end
    expect(BillingSubscription.count).to eq(0)
  end

  it 'rejects new creates with forged current money, catalogue version or malformed lists' do
    changes = [
      ->(terms) { terms[:price_snapshot]['pricing']['monthly_kzt'] += 1 },
      ->(terms) { terms[:plan_snapshot]['catalog_version'] = terms[:price_snapshot]['catalog_version'] = Accounts::Plans.version + 1 },
      ->(terms) { terms[:plan_snapshot]['modules'] = {} }
    ]
    changes.each do |change|
      terms = snapshots.deep_dup
      change.call(terms)
      expect { BillingSubscription.create!(billing_account: payer, **terms) }.to raise_error(ActiveRecord::RecordInvalid, /complete immutable/)
    end
    expect(BillingSubscription.count).to eq(0)
  end

  it 'records adjoining history but SQL refuses unknown, reversed or overlapping ready intervals' do
    start = Time.utc(2026, 11, 1)
    boundary = start + 1.day
    first = BillingAccountWorkspace.create!(billing_account: payer, account: account, starts_at: start, detached_at: boundary, status: 'detached')
    current = BillingAccountWorkspace.create!(billing_account: payer, account: account, starts_at: boundary)
    expect { first.update!(starts_at: start - 1.day) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect { first.update!(detached_at: boundary + 1.hour) }.to raise_error(ActiveRecord::RecordInvalid)
    expect do
      BillingAccountWorkspace.transaction(requires_new: true) do
        BillingAccountWorkspace.create!(billing_account: payer, account: account, starts_at: start + 1.hour,
                                        detached_at: boundary - 1.hour, status: 'detached')
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /excl_billing_workspace_intervals/)
    expect do
      BillingAccountWorkspace.transaction(requires_new: true) { BillingAccountWorkspace.where(id: current.id).update_all(starts_at: nil) }
    end.to raise_error(ActiveRecord::StatementInvalid, /chk_billing_workspaces_known_interval/)
    expect do
      Account.transaction(requires_new: true) { Account.where(id: account.id).delete_all }
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
# rubocop:enable Rails/SkipsModelValidations
