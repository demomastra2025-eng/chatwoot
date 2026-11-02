require 'rails_helper'

RSpec.describe Billing::UsageLedger do
  include BillingUnitLedgerHelpers

  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:package) { ledger_package(accounts: [account]) }
  let(:at) { Time.utc(2026, 11, 5, 8) }

  def recorded_owner(event_at)
    owner = create(:contact, account: account)
    event = ledger_event(account: account, contact: owner, at: event_at)
    inputs = ledger_inputs(account: account, contact: owner, entries: [[event, package]])
    result = described_class.reconcile!(**inputs)
    expect(result[:status]).to eq(:applied)
    { contact: owner, event: event, projection: Billing::UsageProjection.find(result[:projection_id]) }
  end

  def transfer_to_target(*owners)
    # The existing clinical merge transfers canonical events without changing financial ownership.
    Accounts::AiUsageEvent.where(id: owners.map { |owner| owner[:event].id })
                          .update_all(contact_id: contact.id) # rubocop:disable Rails/SkipsModelValidations
  end

  def financial_rows
    [Billing::UsagePeriod, Billing::UsageProjection, Billing::UsageRevision].map { |model| model.order(:id).map(&:attributes) }
  end

  def without_financial_writes(inputs, status:, code:)
    before = financial_rows
    statements = []
    listener = ActiveSupport::Notifications.subscribe('sql.active_record') { |*, payload| statements << payload[:sql] }
    result = described_class.reconcile!(**inputs)
    expect(result).to include(status: status, code: code, deltas: {})
    mutations = statements.grep(/\A\s*(INSERT|UPDATE|DELETE|TRUNCATE|CREATE|ALTER|DROP)\b/i)
    expect(mutations).to be_empty
    expect(financial_rows).to eq(before)
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(listener) if listener
  end

  [true, false].each do |existing_target|
    { 'inside one 24-hour window' => 1.minute, 'in separate windows' => 2.days }.each do |window, interval|
      it "refuses an omitted owner for a #{existing_target ? 'recorded' : 'new'} target #{window} without changing any financial row" do
        source = recorded_owner(at)
        target_event = ledger_event(account: account, contact: contact, at: at + interval)
        target_inputs = ledger_inputs(account: account, contact: contact, entries: [[target_event, package]])
        expect(described_class.reconcile!(**target_inputs)[:status]).to eq(:applied) if existing_target
        transfer_to_target(source)
        inputs = ledger_inputs(account: account, contact: contact, entries: [[source[:event], package], [target_event, package]],
                               version: existing_target ? 1 : 0, baseline: existing_target ? nil : :empty)
        before = financial_rows
        statements = without_financial_writes(inputs, status: :needs_review, code: :merge_owner_missing)
        expect(described_class.preview(**inputs)).to include(status: :needs_review, code: :merge_owner_missing, deltas: {})
        expect(financial_rows).to eq(before)
        account_lock = statements.index { |sql| sql.include?('FROM "accounts"') && sql.include?('FOR NO KEY UPDATE') }
        contact_locks = statements.each_index.select { |index| statements[index].include?('FROM "contacts"') && statements[index].include?('FOR ') }
        expect(account_lock).to be_a(Integer)
        expect(contact_locks).not_to be_empty
        expect(contact_locks).to all(be < account_lock)
        expect(package[:period].reload.dialogs_count).to eq(existing_target ? 2 : 1)
      end
    end
  end

  [false, true].each do |partial_merge|
    it "refuses #{partial_merge ? 'a partial' : 'an entirely omitted'} explicit set across two active owners, then accepts the complete set" do
      first = recorded_owner(at)
      second = recorded_owner(at + 2.days)
      target_event = ledger_event(account: account, contact: contact, at: at + 4.days)
      target = described_class.reconcile!(**ledger_inputs(account: account, contact: contact, entries: [[target_event, package]]))
      expect(target[:status]).to eq(:applied)
      transfer_to_target(first, second)
      owners = [first, second].to_h { |owner| [owner[:projection].id, owner[:projection].version] }
      inputs = ledger_inputs(account: account, contact: contact,
                             entries: [[first[:event], package], [second[:event], package], [target_event, package]],
                             version: target[:version], merge_from: partial_merge ? owners.slice(first[:projection].id) : {})
      without_financial_writes(inputs, status: :needs_review, code: :merge_owner_missing)
      expect(package[:period].reload.dialogs_count).to eq(3)
      complete = inputs.merge(merge_from: owners)
      expect(described_class.reconcile!(**complete)).to include(status: :applied, deltas: {})
      expect(package[:period].reload.dialogs_count).to eq(3)
      expect(Billing::UsageProjection.where(id: owners.keys).pluck(:retired_into_id)).to eq([target[:projection_id]] * 2)
      without_financial_writes(complete, status: :no_op, code: nil)
    end
  end

  it 'posts the explicit same-window correction once and ignores retired history for replay and subsequent replies' do
    source = recorded_owner(at)
    second = ledger_event(account: account, contact: contact, at: at + 1.minute)
    target = described_class.reconcile!(**ledger_inputs(account: account, contact: contact, entries: [[second, package]]))
    expect(target[:status]).to eq(:applied)
    witnesses = Billing::UsageProjection.all.each_with_object({}) { |projection, all| all.merge!(projection.sources) }
    transfer_to_target(source)
    inputs = ledger_inputs(account: account, contact: contact, entries: [[source[:event], package], [second, package]],
                           version: target[:version], merge_from: { source[:projection].id => source[:projection].version })
    expect(described_class.reconcile!(**inputs)).to include(status: :applied, deltas: { package[:period].id => { 'dialogs' => -1, 'seconds' => 0 } })
    retired = source[:projection].reload.attributes
    expect([retired['retired_into_id'], package[:period].reload.dialogs_count]).to eq([target[:projection_id], 1])
    without_financial_writes(inputs, status: :no_op, code: nil)
    without_financial_writes(inputs.merge(merge_from: {}, expected_version: 2), status: :no_op, code: nil)
    third = ledger_event(account: account, contact: contact, at: at + 2.minutes)
    amended = ledger_inputs(account: account, contact: contact, entries: [[source[:event], package], [second, package], [third, package]], version: 2)
    expect(described_class.reconcile!(**amended)).to include(status: :applied, deltas: {}, version: 3)
    expect(Billing::UsageProjection.find(target[:projection_id]).sources.slice(*witnesses.keys)).to eq(witnesses)
    expect(source[:projection].reload.attributes).to eq(retired)
    expect([package[:period].reload.dialogs_count, Billing::UsageRevision.count]).to eq([1, 3])
  end

  it 'requires the versioned financial owner after clinical source deletion and can merge it into a new target' do
    source = recorded_owner(at)
    witness = source[:projection].sources.deep_dup
    transfer_to_target(source)
    Contact.where(id: source[:contact].id).delete_all
    inputs = ledger_inputs(account: account, contact: contact, entries: [[source[:event], package]], baseline: :empty)
    without_financial_writes(inputs, status: :needs_review, code: :merge_owner_missing)
    explicit = inputs.merge(baseline: nil, merge_from: { source[:projection].id => source[:projection].version })
    result = described_class.reconcile!(**explicit)
    expect(result).to include(status: :applied, deltas: {})
    expect(Billing::UsageProjection.find(result[:projection_id]).sources).to eq(witness)
    expect(source[:projection].reload.retired_into_id).to eq(result[:projection_id])
    expect([package[:period].reload.dialogs_count, Billing::UsageRevision.count]).to eq([1, 1])
    without_financial_writes(explicit, status: :no_op, code: nil)
  end

  it 'refuses a complete owner set with a stale source version before any financial mutation' do
    source = recorded_owner(at)
    target_event = ledger_event(account: account, contact: contact, at: at + 2.days)
    target = described_class.reconcile!(**ledger_inputs(account: account, contact: contact, entries: [[target_event, package]]))
    expect(target[:status]).to eq(:applied)
    transfer_to_target(source)
    inputs = ledger_inputs(account: account, contact: contact, entries: [[source[:event], package], [target_event, package]],
                           version: target[:version], merge_from: { source[:projection].id => source[:projection].version + 1 })
    without_financial_writes(inputs, status: :conflict, code: :stale_projection)
  end
end
