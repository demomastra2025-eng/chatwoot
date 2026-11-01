# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Billing::ClosingDocumentsService do
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
  let(:account) { create(:account, name: 'ТОО Med Clinic') }
  let(:invoice) do
    Billing::AccountProfile.create!(account: account, billing_enabled: true, billing_tax_id: '190140098765', contract_number: 'ДГ-99')
    Billing::Invoice.create!(
      account: account,
      invoice_number: 'OL-202611-0099-01',
      status: 'paid',
      paid_at: Time.current,
      period_start: Date.new(2026, 11, 1),
      period_end: Date.new(2026, 12, 1),
      due_on: Date.new(2026, 11, 1),
      currency: 'KZT',
      base_amount_minor: 9_900_000,
      amount_minor: 9_900_000,
      partner_commission_base_minor: 9_900_000,
      payer_tax_id: '190140098765',
      payer_legal_name: 'ТОО Med Clinic',
      knp_code: '859',
      payment_purpose: 'Оплата за доступ к платформе OneLink по счёту № OL-202611-0099-01 (без НДС)',
      line_items: [{ 'description' => 'Тариф Переписка + звонки', 'quantity' => 1, 'unit_price_minor' => 9_900_000, 'amount_minor' => 9_900_000 }]
    )
  end
  let(:configured_env) do
    {
      'UCHET_EDO_BASE_URL' => 'https://edo.uchet.kz',
      'UCHET_EDO_API_TOKEN' => 'edo_tok',
      'SIGEX_BASE_URL' => 'https://sigex.kz',
      'SIGEX_API_TOKEN' => 'sig_tok',
      'IS_ESF_BASE_URL' => 'https://esf.gov.kz',
      'IS_ESF_API_TOKEN' => 'esf_tok',
      'BCC_SUPPLIER_BIN' => '980123456789',
      'BCC_BUSINESS_IBAN' => 'KZ128560000000123456'
    }
  end

  it 'records pending_configuration safely when EDO/ESF credentials are not configured' do
    unconfigured = configured_env.transform_values { nil }
    with_billing_env(unconfigured) do
      Billing::ClosingDocumentsJob.perform_now(invoice.id)
    end

    expect(invoice.reload).to have_attributes(edo_status: 'pending_configuration', edo_document_id: nil)
  end

  it 'signs EAVR via SIGEX, sends to Uchet.EDO, and issues ESF via IS ESF upon counterparty signature' do
    stub_request(:post, 'https://sigex.kz/api/sign')
      .to_return(status: 200, body: { signature: 'CMS_BASE64_SIG', sign_id: 'sig-1' }.to_json)
    stub_request(:post, 'https://edo.uchet.kz/api/v1/eavr')
      .to_return(status: 200, body: { document_id: 'EDO-DOC-777', status: 'sent_for_signature' }.to_json)
    stub_request(:post, 'https://esf.gov.kz/api/v1/esf')
      .to_return(status: 200, body: { esf_id: 'ESF-KZ-2026-555' }.to_json)

    with_billing_env(configured_env) do
      described_class.new(invoice: invoice).send_eavr!
      expect(invoice.reload).to have_attributes(edo_document_id: 'EDO-DOC-777', edo_status: 'sent_for_signature')

      described_class.process_counterparty_signature!(invoice, signed_at: Time.current)
    end

    expect(invoice.reload).to have_attributes(
      edo_status: 'signed',
      esf_id: 'ESF-KZ-2026-555',
      esf_status: 'issued'
    )
    expect(invoice.signed_by_counterparty_at).to be_present
  end

  it 'short-circuits when edo_document_id exists, backfills BIN from profile, and alerts Account #48 if BIN is missing' do
    owner_workspace
    invoice.update!(edo_document_id: 'EDO-ALREADY-1', edo_status: 'signed')
    with_billing_env(configured_env) { described_class.new(invoice: invoice).send_eavr! }
    expect(invoice.reload.edo_status).to eq('signed')

    stub_request(:post, 'https://sigex.kz/api/sign')
      .to_return(status: 200, body: { signature: 'CMS_SIG', sign_id: 's1' }.to_json)
    stub_request(:post, 'https://edo.uchet.kz/api/v1/eavr')
      .to_return(status: 200, body: { document_id: 'EDO-BACKFILLED-1', status: 'sent_for_signature' }.to_json)
    invoice.update!(edo_document_id: nil, edo_status: nil, payer_tax_id: nil)
    with_billing_env(configured_env) { described_class.new(invoice: invoice).send_eavr! }
    expect(invoice.reload).to have_attributes(payer_tax_id: '190140098765', edo_document_id: 'EDO-BACKFILLED-1')

    invoice.update!(edo_document_id: nil, edo_status: nil, payer_tax_id: nil)
    account.billing_account_profile.update!(billing_tax_id: nil)
    with_billing_env(configured_env) { described_class.new(invoice: invoice).send_eavr! }

    expect(invoice.reload.edo_status).to eq('failed')
    expect(Crm::Task.exists?(account_id: owner_workspace.id, idempotency_key: 'billing:edo_missing_bin:OL-202611-0099-01')).to be(true)
  end

  it 'clamps future-skewed signed_at to today_almaty and persists failed status before re-raising on ApiError' do
    stub_request(:post, 'https://sigex.kz/api/sign')
      .to_return(status: 200, body: { signature: 'CMS_BASE64_SIG', sign_id: 'sig-1' }.to_json)
    stub_request(:post, 'https://edo.uchet.kz/api/v1/eavr').to_return(status: 503, body: 'EDO Down')

    with_billing_env(configured_env) do
      expect { described_class.new(invoice: invoice).send_eavr! }.to raise_error(Billing::UchetEdoClient::ApiError)
    end
    expect(invoice.reload.edo_status).to eq('failed')
    expect(invoice.metadata['edo_last_error']).to include('503')

    stub_request(:post, 'https://esf.gov.kz/api/v1/esf')
      .to_return(status: 200, body: { esf_id: 'ESF-CLAMPED-1' }.to_json)
    with_billing_env(configured_env) do
      described_class.process_counterparty_signature!(invoice, signed_at: 2.days.from_now)
    end
    expect(invoice.reload.metadata['esf_turnover_date']).to eq(Billing.today_almaty.iso8601)
  end

  it 'flags deadline_exceeded and alerts owner in Account #48 if counterparty signed > 15 days ago' do
    owner_workspace
    with_billing_env(configured_env) do
      described_class.process_counterparty_signature!(invoice, signed_at: 17.days.ago)
    end

    expect(invoice.reload).to have_attributes(edo_status: 'signed', esf_status: 'deadline_exceeded', esf_id: nil)
    expect(Crm::Task.exists?(account_id: owner_workspace.id, idempotency_key: 'billing:esf_deadline:OL-202611-0099-01')).to be(true)
  end
end
