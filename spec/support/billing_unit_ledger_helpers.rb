module BillingUnitLedgerHelpers
  LEDGER_MONTH = Date.new(2026, 11, 1)

  def ledger_package(accounts:, month: LEDGER_MONTH, from: Time.utc(2026, 10, 1), to: nil, tariff: 'text_call')
    organization = create(:organization)
    accounts.each { |account| account.update!(organization: organization) }
    payer = BillingAccount.create!(name: 'Synthetic ledger payer', organization: organization)
    terms = Billing::PlanSnapshot.compile(tariff: tariff, defaults: Accounts::Plans::LIMIT_KEYS.index_with(nil))
    subscription = BillingSubscription.create!(billing_account: payer, status: 'active', created_at: Time.utc(2026, 9, 1), **terms)
    period = ledger_period(payer: payer, subscription: subscription, month: month)
    workspaces = accounts.to_h do |account|
      workspace = BillingAccountWorkspace.create!(account: account, billing_account: payer, starts_at: from,
                                                  detached_at: to, status: to ? 'detached' : 'active')
      [account.id, workspace]
    end
    { payer: payer, subscription: subscription, period: period, workspaces: workspaces }
  end

  def ledger_period(payer:, subscription:, month: LEDGER_MONTH)
    zone = ActiveSupport::TimeZone[Billing::ALMATY_TIMEZONE]
    subscription.update!(current_period_starts_at: zone.local(month.prev_month.year, month.prev_month.month, 15),
                         current_period_ends_at: zone.local(month.year, month.month, 15))
    Billing::UsagePeriod.create!(billing_account: payer, billing_subscription: subscription, month: month,
                                 plan_snapshot: subscription.plan_snapshot.deep_dup, price_snapshot: subscription.price_snapshot.deep_dup)
  end

  def ledger_event(account:, at:, contact: nil, seconds: nil)
    bucket = seconds ? Accounts::MonthlyAiUsageService::CALL_SECONDS_MONTHLY_KEY : Accounts::MonthlyAiUsageService::AI_DIALOGS_MONTHLY_KEY
    Accounts::AiUsageEvent.create!(account: account, contact_id: contact&.id, occurred_at: at, quantity: seconds || 1,
                                   bucket: bucket, event_key: "ledger-test:#{SecureRandom.uuid}")
  end

  def ledger_inputs(account:, entries:, **options)
    provenance = entries.to_h do |event, package|
      [event.id, { workspace_id: package[:workspaces].fetch(account.id).id,
                   period_id: package[:period].id, subscription_id: package[:subscription].id }]
    end
    { account_id: account.id, contact_id: options[:contact]&.id, event_ids: entries.map { |event, _| event.id }, provenance: provenance,
      expected_version: options.fetch(:version, 0), merge_from: options.fetch(:merge_from, {}), baseline: options.fetch(:baseline, :empty) }
  end
end
