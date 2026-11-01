# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Billing::PaymentMatcher do
  include ActiveJob::TestHelper

  def with_billing_env(overrides)
    previous = overrides.keys.index_with { |key| ENV.fetch(key, nil) }
    overrides.each { |key, val| val.nil? ? ENV.delete(key) : ENV[key] = val }
    yield
  ensure
    previous.each { |key, val| val.nil? ? ENV.delete(key) : ENV[key] = val }
  end

  let(:owner_user) do
    user = User.find_by(id: 6) || create(:user, id: 6)
    ActiveRecord::Base.connection.reset_pk_sequence!('users')
    user
  end
  let(:owner_workspace) do
    ws = Account.find_by(id: 48) || create(:account, id: 48, name: 'Owner Workspace')
    ActiveRecord::Base.connection.reset_pk_sequence!('accounts')
    AccountUser.find_or_create_by!(account: ws, user: owner_user) { |au| au.role = :administrator }
    ws
  end
  let!(:bcc_finance_account) do
    OwnerFinance::AccountRecord.create!(
      name: 'БЦК Расчётный KZT',
      scope: 'business',
      account_kind: 'business_bank',
      bank_code: 'bcc',
      currency: 'KZT',
      active: true
    )
  end
  let(:clinic) { create(:account, name: 'ТОО Green Clinic') }
  let!(:profile) do
    Accounts::ApplyPlan.new(account: clinic, tariff: 'ai_agent_rop').call
    Billing::AccountProfile.create!(
      account: clinic,
      billing_enabled: true,
      paid_until: Date.new(2026, 1, 31),
      billing_day: 31,
      billing_tax_id: '210540012345',
      legal_name: 'ТОО Green Clinic',
      payment_overdue_banner: true,
      overdue_invoice_number: 'OL-202601-0001-01',
      partner_commission_rate_pct: 30
    )
  end

  def create_open_invoice(
    target_account: clinic, period_start: Date.new(2026, 1, 31),
    base_minor: 19_900_000, overage_minor: 610_000, payer_tax_id: '210540012345'
  )
    target_profile = target_account.billing_account_profile
    period_end = target_profile ? target_profile.next_period_end_from(period_start) : period_start.next_month
    Billing::Invoice.create!(
      account: target_account, status: 'issued', currency: 'KZT', plan_key: 'ai_agent_rop',
      invoice_number: format('OL-%<ym>s-%<id>04d-01', ym: period_start.strftime('%Y%m'), id: target_account.id),
      period_start: period_start, period_end: period_end, due_on: period_start,
      base_amount_minor: base_minor, ai_dialogs_overage_count: 120, ai_dialogs_overage_minor: overage_minor,
      amount_minor: base_minor + overage_minor, partner_commission_base_minor: base_minor,
      payer_tax_id: payer_tax_id, payer_legal_name: target_account.name, knp_code: '859',
      payment_purpose: 'Оплата за доступ к платформе OneLink (без НДС)'
    )
  end

  it 'settles exact OL code match atomically, preserves billing anchor day, records OwnerFinance + 30% base obligation, and enqueues EAVR' do
    invoice = create_open_invoice
    payload = {
      bank_reference_id: 'BCC-REF-1001',
      amount_minor: 20_510_000,
      currency: 'KZT',
      sender_tax_id: '210540012345',
      sender_name: 'ТОО Green Clinic',
      payment_purpose: "Оплата по счёту #{invoice.invoice_number} без НДС",
      occurred_at: '2026-01-28T11:15:00+05:00'
    }

    event = nil
    assert_enqueued_with(job: Billing::ClosingDocumentsJob, args: [invoice.id]) do
      event = described_class.new(source: 'bcc_open_api', payload: payload).perform
    end

    expect(event).to have_attributes(status: 'matched', billing_invoice_id: invoice.id)
    expect(invoice.reload).to have_attributes(status: 'paid', bank_reference_id: 'BCC-REF-1001')
    expect(profile.reload).to have_attributes(
      paid_until: Date.new(2026, 2, 28), billing_day: 31,
      payment_overdue_banner: false, overdue_invoice_number: nil
    )

    tx = OwnerFinance::TransactionRecord.find_by!(external_source_key: 'billing:bcc_open_api:BCC-REF-1001')
    obligation = OwnerFinance::Obligation.find_by!(external_source_key: "billing:medelement_commission:#{invoice.invoice_number}")
    expect(tx).to have_attributes(account_record_id: bcc_finance_account.id, amount_kzt: BigDecimal('205100.00'), review_status: 'confirmed')
    expect(obligation).to have_attributes(
      base_amount: BigDecimal('199000.00'),
      overage_excluded_amount: BigDecimal('6100.00'),
      amount: BigDecimal('59700.00')
    )
  end

  it 'creates zero partner obligations for direct clinics (0% default) and preserves paid obligation state on re-upsert' do
    direct_clinic = create(:account, name: 'ТОО Direct Clinic')
    direct_profile = Billing::AccountProfile.create!(account: direct_clinic, billing_enabled: true, paid_until: Date.new(2026, 2, 10))
    direct_invoice = create_open_invoice(target_account: direct_clinic, period_start: Date.new(2026, 2, 10), overage_minor: 0, payer_tax_id: nil)

    described_class.new(
      source: 'bcc_open_api',
      payload: { bank_reference_id: 'BCC-DIRECT-1', amount_minor: 19_900_000, currency: 'KZT', payment_purpose: direct_invoice.invoice_number }
    ).perform

    expect(direct_profile.partner_commission_rate_pct).to eq(0)
    expect(OwnerFinance::Obligation.exists?(external_source_key: "billing:medelement_commission:#{direct_invoice.invoice_number}")).to be(false)

    partner_invoice = create_open_invoice(overage_minor: 0)
    recorder = Billing::OwnerFinanceRecorder.new
    ev_attrs = { source: 'bcc_open_api', bank_reference_id: 'BCC-PARTNER-1', amount_minor: 19_900_000, currency: 'KZT', occurred_at: Time.current }
    recorder.record_matched_payment!(invoice: partner_invoice, profile: profile, event_attrs: ev_attrs)
    obligation = OwnerFinance::Obligation.find_by!(external_source_key: "billing:medelement_commission:#{partner_invoice.invoice_number}")
    obligation.update!(paid_amount: BigDecimal('59700.00'), status: 'paid')

    recorder.record_matched_payment!(invoice: partner_invoice, profile: profile, event_attrs: ev_attrs)
    expect(obligation.reload).to have_attributes(paid_amount: BigDecimal('59700.00'), status: 'paid')
  end

  it 'restores 31st billing anchor day when advancing from Feb 28 to Mar 31 and is idempotent on duplicate bank_reference_id' do
    profile.update!(paid_until: Date.new(2026, 2, 28), billing_day: 31)
    invoice = create_open_invoice(period_start: Date.new(2026, 2, 28), overage_minor: 0)
    payload = {
      bank_reference_id: 'BCC-REF-FEB28',
      amount_minor: 19_900_000,
      currency: 'KZT',
      payment_purpose: "Счёт #{invoice.invoice_number}",
      occurred_at: '2026-02-27T10:00:00+05:00'
    }

    first_event = described_class.new(source: 'bcc_open_api', payload: payload).perform
    duplicate_event = described_class.new(source: 'bcc_open_api', payload: payload).perform

    expect(duplicate_event.id).to eq(first_event.id)
    expect(profile.reload.paid_until).to eq(Date.new(2026, 3, 31))
    expect(OwnerFinance::TransactionRecord.where(external_source_key: 'billing:bcc_open_api:BCC-REF-FEB28').count).to eq(1)
  end

  it 'matches by Organization#bin when profile.billing_tax_id is nil and strips nested sensitive card keys from raw_payload' do
    org = Organization.create!(name: 'Org Clinic', bin: '210540012341')
    org_clinic = create(:account, name: 'ТОО Org Clinic', organization: org)
    Billing::AccountProfile.create!(account: org_clinic, billing_enabled: true, billing_tax_id: nil, paid_until: Date.new(2026, 3, 15))
    org_invoice = create_open_invoice(target_account: org_clinic, period_start: Date.new(2026, 3, 15), overage_minor: 0, payer_tax_id: nil)

    event = described_class.new(
      source: 'bcc_open_api',
      payload: {
        bank_reference_id: 'BCC-ORG-BIN-1',
        amount_minor: 19_900_000,
        currency: 'KZT',
        sender_tax_id: '210540012341',
        payment_purpose: 'Оплата за медицинскую платформу без номера счёта',
        card_token: 'secret_tok_top',
        nested: { pan: '4400111122223333', cvv: '999', safe_note: 'kept' }
      }
    ).perform

    expect(event).to have_attributes(status: 'matched', billing_invoice_id: org_invoice.id)
    expect(event.raw_payload.keys).not_to include('card_token')
    expect(event.raw_payload['nested']).to eq('safe_note' => 'kept')
  end

  it 'flags overpayment on OL code match with needs_review finance transaction, overpayment metadata, and Account #48 alert task' do
    owner_workspace
    invoice = create_open_invoice(overage_minor: 0)

    event = described_class.new(
      source: 'bcc_open_api',
      payload: {
        bank_reference_id: 'BCC-OVERPAY-1',
        amount_minor: 25_000_000,
        currency: 'KZT',
        sender_tax_id: '210540012345',
        payment_purpose: "Оплата по счёту #{invoice.invoice_number}"
      }
    ).perform

    expect(invoice.reload.status).to eq('paid')
    expect(event).to have_attributes(status: 'matched', review_reason: 'overpayment')
    expect(event.metadata).to include('overpayment_minor' => 5_100_000, 'invoice_amount_minor' => 19_900_000)

    tx = OwnerFinance::TransactionRecord.find_by!(external_source_key: 'billing:bcc_open_api:BCC-OVERPAY-1')
    expect(tx.review_status).to eq('needs_review')
    expect(Crm::Task.exists?(account_id: owner_workspace.id, idempotency_key: 'billing:payment_review:bcc_open_api:BCC-OVERPAY-1')).to be(true)
  end

  it 'handles unsupported currencies without crashing sync and creates an Account #48 task' do
    owner_workspace
    invoice = create_open_invoice(overage_minor: 0)

    event = described_class.new(
      source: 'bcc_open_api',
      payload: {
        bank_reference_id: 'BCC-CNY-1',
        amount_minor: 5_000_000,
        currency: 'CNY',
        sender_tax_id: '210540012345',
        payment_purpose: "Оплата #{invoice.invoice_number}"
      }
    ).perform

    expect(event).to have_attributes(status: 'needs_review', currency: 'CNY')
    expect(event.metadata['unsupported_currency']).to eq('CNY')
    expect(OwnerFinance::TransactionRecord.exists?(external_source_key: 'billing:bcc_open_api:BCC-CNY-1')).to be(false)
    expect(Crm::Task.exists?(account_id: owner_workspace.id, idempotency_key: 'billing:payment_review:bcc_open_api:BCC-CNY-1')).to be(true)
  end

  it 'routes partial and multi-invoice BIN payments to needs_review with Account #48 CRM tasks' do
    owner_workspace
    first_inv = create_open_invoice(period_start: Date.new(2026, 1, 31), overage_minor: 0)
    second_inv = create_open_invoice(period_start: Date.new(2026, 2, 28), overage_minor: 0)

    partial = described_class.new(
      source: 'bcc_open_api',
      payload: {
        bank_reference_id: 'BCC-REF-PARTIAL', amount_minor: 10_000_000, currency: 'KZT',
        payment_purpose: "Частичная оплата по #{first_inv.invoice_number}"
      }
    ).perform
    multi = described_class.new(
      source: 'bcc_open_api',
      payload: {
        bank_reference_id: 'BCC-REF-MULTI', amount_minor: 19_900_000, currency: 'KZT',
        sender_tax_id: '210540012345', payment_purpose: 'Оплата по договору'
      }
    ).perform

    expect(partial).to have_attributes(status: 'needs_review', review_reason: 'partial_amount')
    expect(multi).to have_attributes(status: 'needs_review', review_reason: 'multiple_open_invoices')
    expect(first_inv.reload.status).to eq('issued')
    expect(second_inv.reload.status).to eq('issued')
    expect(Crm::Task.exists?(account_id: owner_workspace.id, idempotency_key: 'billing:payment_review:bcc_open_api:BCC-REF-PARTIAL')).to be(true)
  end

  it 'drains multi-page BCC statements before advancing last_synced_at and preserves last_synced_at on ApiError' do
    jan_inv = create_open_invoice(period_start: Date.new(2026, 1, 31), overage_minor: 0)
    feb_inv = create_open_invoice(period_start: Date.new(2026, 2, 28), overage_minor: 0)
    stub_request(:post, 'https://api.bcc.kz/v1/oauth/token')
      .to_return(status: 200, body: { access_token: 'bcc_tok_123' }.to_json)
    stub_request(:get, %r{\Ahttps://api\.bcc\.kz/v1/statements\?})
      .with { |req| req.uri.query.exclude?('cursor=') }
      .to_return(
        status: 200,
        body: {
          transactions: [{ id: 'STMT-P1', amount: '199000.00', currency: 'KZT', purpose: "Счёт #{jan_inv.invoice_number}" }],
          next_cursor: 'cur_page_2'
        }.to_json
      )
    stub_request(:get, %r{\Ahttps://api\.bcc\.kz/v1/statements\?.*cursor=cur_page_2})
      .to_return(
        status: 200,
        body: {
          transactions: [{ id: 'STMT-P2', amount: '199000.00', currency: 'KZT', purpose: "Счёт #{feb_inv.invoice_number}" }],
          next_cursor: nil
        }.to_json
      )

    env = {
      'BILLING_AUTOBILLING_ENABLED' => 'true', 'BCC_OPEN_API_BASE_URL' => 'https://api.bcc.kz/v1',
      'BCC_OPEN_API_CLIENT_ID' => 'cid', 'BCC_OPEN_API_CLIENT_SECRET' => 'csec', 'BCC_BUSINESS_IBAN' => 'KZ128560000000111222'
    }
    with_billing_env(env) { Billing::BccStatementSyncJob.perform_now }

    sync_state = OwnerFinance::SyncState.find_by!(sync_key: 'bcc_open_api')
    saved_synced_at = sync_state.last_synced_at
    expect(jan_inv.reload.status).to eq('paid')
    expect(feb_inv.reload.status).to eq('paid')
    expect(sync_state.summary).to include('pages' => 2, 'matched' => 2, 'next_cursor' => nil)

    WebMock.reset!
    stub_request(:post, 'https://api.bcc.kz/v1/oauth/token').to_return(status: 502, body: 'Bad Gateway')
    with_billing_env(env) { Billing::BccStatementSyncJob.perform_now }
    expect(sync_state.reload).to have_attributes(sync_status: 'error', last_synced_at: saved_synced_at)
  end
end
