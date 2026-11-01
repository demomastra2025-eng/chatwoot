# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Billing::InvoiceGeneratorService do
  include ActiveSupport::Testing::TimeHelpers

  def with_billing_env(overrides)
    previous = overrides.keys.index_with { |key| ENV.fetch(key, nil) }
    overrides.each { |key, val| val.nil? ? ENV.delete(key) : ENV[key] = val }
    yield
  ensure
    previous.each { |key, val| val.nil? ? ENV.delete(key) : ENV[key] = val }
  end

  let(:account) { create(:account, name: 'ТОО Green Clinic') }
  let(:period_start) { Date.new(2026, 11, 15) }
  let!(:profile) do
    Accounts::ApplyPlan.new(account: account, tariff: 'ai_agent_rop').call
    Billing::AccountProfile.create!(
      account: account,
      billing_enabled: true,
      paid_until: period_start,
      billing_tax_id: '210540012345',
      legal_name: 'ТОО Green Clinic',
      contract_number: 'ДГ-2026/74',
      knp_code: '859'
    )
  end

  it 'generates sequential OL-YYYYMM-AAAA-SS invoice with valid Cyrillic + Latin PDF attachment' do
    expected_prefix = format('OL-202611-%<id>04d-01', id: account.id)
    env = { 'BCC_SUPPLIER_BIN' => '980123456789', 'BCC_BUSINESS_IBAN' => 'KZ128560000000654321' }

    invoice = with_billing_env(env) do
      described_class.new(account: account, period_start: period_start).perform
    end

    expect(invoice).to have_attributes(
      invoice_number: expected_prefix,
      status: 'issued',
      amount_minor: 19_900_000,
      payment_purpose: "Оплата за доступ к платформе OneLink по счёту № #{expected_prefix} (без НДС)"
    )
    expect(invoice.pdf_file).to be_attached

    pdf_bytes = invoice.pdf_file.download
    expect(pdf_bytes.byteslice(0, 8)).to eq('%PDF-1.4')

    Tempfile.create(['invoice_spec', '.pdf'], binmode: true) do |tmp|
      tmp.write(pdf_bytes)
      tmp.flush
      extracted = `/usr/bin/pdftotext -enc UTF-8 #{tmp.path} -`
      expect(extracted).to include(expected_prefix, '210540012345', 'KZ128560000000654321', 'KCJBKZKX', '199 000.00 KZT', 'Оплата за доступ')
    end
  end

  it 'is idempotent on [account_id, period_start] and increments sequence -02 after cancellation' do
    first = described_class.new(account: account, period_start: period_start).perform
    duplicate = described_class.new(account: account, period_start: period_start).perform

    expect(duplicate.id).to eq(first.id)
    expect(Billing::Invoice.where(account_id: account.id).count).to eq(1)

    first.update!(status: 'cancelled')
    reissued = described_class.new(account: account, period_start: period_start).perform
    expect(reissued.invoice_number).to eq(format('OL-202611-%<id>04d-02', id: account.id))
  end

  it 'runs GenerateUpcomingInvoicesJob for enabled profiles at T-5 days in Asia/Almaty' do
    other_account = create(:account)
    Accounts::ApplyPlan.new(account: other_account, tariff: 'text_call').call
    Billing::AccountProfile.create!(account: other_account, billing_enabled: true, paid_until: Date.new(2026, 11, 16))
    profile.update!(paid_until: Date.new(2026, 11, 15))

    travel_to(Time.find_zone('Asia/Almaty').local(2026, 11, 10, 10, 0, 0)) do
      with_billing_env('BILLING_AUTOBILLING_ENABLED' => 'true') do
        Billing::GenerateUpcomingInvoicesJob.perform_now
      end
    end

    expect(account.billing_invoices.count).to eq(1)
    expect(other_account.billing_invoices.count).to eq(0)
  end
end
