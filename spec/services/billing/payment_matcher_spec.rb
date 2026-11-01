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

  def create_open_invoice(period_start: Date.new(2026, 1, 31), base_minor: 19_900_000, overage_minor: 610_000)
    Billing::Invoice.create!(
      account: clinic,
      invoice_number: format('OL-%<ym>s-%<id>04d-01', ym: period_start.strftime('%Y%m'), id: clinic.id),
      status: 'issued',
      period_start: period_start,
      period_end: period_start.next_month,
      due_on: period_start,
      currency: 'KZT',
      plan_key: 'ai_agent_rop',
      base_amount_minor: base_minor,
      ai_dialogs_overage_count: 120,
      ai_dialogs_overage_minor: overage_minor,
      amount_minor: base_minor + overage_minor,
      partner_commission_base_minor: base_minor,
      payer_tax_id: '210540012345',
      payer_legal_name: 'ТОО Green Clinic',
      knp_code: '859',
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

  it 'auto-matches by 12-digit sender BIN when strictly one open invoice matches exact amount' do
    invoice = create_open_invoice(overage_minor: 0)
    payload = {
      bank_reference_id: 'BCC-REF-BIN-EXACT',
      amount_minor: 19_900_000,
      currency: 'KZT',
      sender_tax_id: '210540012345',
      sender_name: 'ТОО Green Clinic',
      payment_purpose: 'За услуги платформы за февраль без НДС',
      occurred_at: '2026-01-30T15:00:00+05:00'
    }

    event = described_class.new(source: 'bcc_open_api', payload: payload).perform

    expect(event).to have_attributes(status: 'matched', billing_invoice_id: invoice.id)
    expect(invoice.reload.status).to eq('paid')
  end

  it 'routes partial payments to needs_review, creates Account #48 CRM task, and leaves paid_until unchanged' do
    owner_workspace
    invoice = create_open_invoice(overage_minor: 0)
    payload = {
      bank_reference_id: 'BCC-REF-PARTIAL',
      amount_minor: 10_000_000,
      currency: 'KZT',
      sender_tax_id: '210540012345',
      payment_purpose: "Частичная оплата по #{invoice.invoice_number}",
      occurred_at: '2026-01-30T15:00:00+05:00'
    }

    event = described_class.new(source: 'bcc_open_api', payload: payload).perform

    expect(event).to have_attributes(status: 'needs_review', review_reason: 'partial_amount', billing_invoice_id: invoice.id)
    expect(invoice.reload.status).to eq('issued')
    expect(profile.reload.paid_until).to eq(Date.new(2026, 1, 31))

    task = Crm::Task.find_by(account_id: owner_workspace.id, idempotency_key: 'billing:payment_review:bcc_open_api:BCC-REF-PARTIAL')
    tx = OwnerFinance::TransactionRecord.find_by(external_source_key: 'billing:bcc_open_api:BCC-REF-PARTIAL')
    expect(task).to have_attributes(assignee_id: owner_user.id, priority: 'high')
    expect(tx.review_status).to eq('needs_review')
  end

  it 'routes ambiguous BIN payment to needs_review when multiple open invoices exist' do
    owner_workspace
    first_inv = create_open_invoice(period_start: Date.new(2026, 1, 31), overage_minor: 0)
    second_inv = create_open_invoice(period_start: Date.new(2026, 2, 28), overage_minor: 0)

    event = described_class.new(
      source: 'bcc_open_api',
      payload: {
        bank_reference_id: 'BCC-REF-MULTI',
        amount_minor: 19_900_000,
        currency: 'KZT',
        sender_tax_id: '210540012345',
        payment_purpose: 'Оплата по договору'
      }
    ).perform

    expect(event).to have_attributes(status: 'needs_review', review_reason: 'multiple_open_invoices')
    expect(first_inv.reload.status).to eq('issued')
    expect(second_inv.reload.status).to eq('issued')
    expect(Crm::Task.exists?(account_id: owner_workspace.id, idempotency_key: 'billing:payment_review:bcc_open_api:BCC-REF-MULTI')).to be(true)
  end

  it 'polls BCC Open API statements in BccStatementSyncJob and updates OwnerFinance::SyncState cursor' do
    invoice = create_open_invoice(overage_minor: 0)
    stub_request(:post, 'https://api.bcc.kz/v1/oauth/token')
      .to_return(status: 200, body: { access_token: 'bcc_tok_123' }.to_json, headers: { 'Content-Type' => 'application/json' })
    stub_request(:get, %r{\Ahttps://api\.bcc\.kz/v1/statements\?})
      .to_return(
        status: 200,
        body: {
          transactions: [
            { id: 'STMT-1', amount: '199000.00', currency: 'KZT', payer_bin: '210540012345', purpose: "Счёт #{invoice.invoice_number}" }
          ],
          next_cursor: 'cur_next_99'
        }.to_json
      )

    env = {
      'BILLING_AUTOBILLING_ENABLED' => 'true',
      'BCC_OPEN_API_BASE_URL' => 'https://api.bcc.kz/v1',
      'BCC_OPEN_API_CLIENT_ID' => 'cid',
      'BCC_OPEN_API_CLIENT_SECRET' => 'super_secret_val',
      'BCC_BUSINESS_IBAN' => 'KZ128560000000111222'
    }
    with_billing_env(env) { Billing::BccStatementSyncJob.perform_now }

    sync_state = OwnerFinance::SyncState.find_by!(sync_key: 'bcc_open_api')
    expect(invoice.reload.status).to eq('paid')
    expect(sync_state).to have_attributes(sync_status: 'ok')
    expect(sync_state.summary).to include('matched' => 1, 'next_cursor' => 'cur_next_99')
  end
end
