# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Billing::BccRecurringChargeJob do
  include ActiveSupport::Testing::TimeHelpers

  def with_billing_env(overrides)
    previous = overrides.keys.index_with { |key| ENV.fetch(key, nil) }
    overrides.each { |key, val| val.nil? ? ENV.delete(key) : ENV[key] = val }
    yield
  ensure
    previous.each { |key, val| val.nil? ? ENV.delete(key) : ENV[key] = val }
  end

  let(:ecom_env) do
    {
      'BILLING_AUTOBILLING_ENABLED' => 'true',
      'BCC_ECOM_BASE_URL' => 'https://ecom.bcc.kz',
      'BCC_ECOM_MERCHANT_ID' => 'm_onelink',
      'BCC_ECOM_TERMINAL_ID' => 't_onelink',
      'BCC_ECOM_SECRET_KEY' => 'ecom_hmac_secret_123'
    }
  end
  let(:clinic) { create(:account, name: 'ТОО Dental Plus') }

  it 'charges Card-on-File on due date and settles invoice via PaymentMatcher' do
    Accounts::ApplyPlan.new(account: clinic, tariff: 'text_call').call
    profile = Billing::AccountProfile.create!(
      account: clinic, billing_enabled: true, paid_until: Billing.today_almaty,
      autopay_enabled: true, bcc_card_token: 'tok_card_abc', bcc_card_masked: '4400********1234'
    )
    stub_request(:post, 'https://ecom.bcc.kz/recurring/charge')
      .to_return(status: 200, body: { approved: true, rrn: 'RRN-9001', status: 'approved' }.to_json)

    with_billing_env(ecom_env) { described_class.perform_now }

    invoice = clinic.billing_invoices.first
    expect(invoice).to have_attributes(status: 'paid', bank_reference_id: 'RRN-9001', recurring_attempts_count: 1)
    expect(profile.reload.paid_until).to eq(Billing.today_almaty + 1.month)
  end

  it 'retries failed recurring charges 3 times spaced by 24h and falls back to PDF invoice + payment link' do
    Accounts::ApplyPlan.new(account: clinic, tariff: 'text_call').call
    due_date = Date.new(2026, 11, 10)
    Billing::AccountProfile.create!(
      account: clinic, billing_enabled: true, paid_until: due_date,
      autopay_enabled: true, bcc_card_token: 'tok_declined'
    )
    invoice = Billing::InvoiceGeneratorService.new(account: clinic, period_start: due_date, due_on: due_date, notify: false).perform
    stub_request(:post, 'https://ecom.bcc.kz/recurring/charge')
      .to_return(status: 200, body: { approved: false, status: 'declined', message: 'Insufficient funds' }.to_json)

    base_time = Time.find_zone('Asia/Almaty').local(2026, 11, 10, 10, 15, 0)
    with_billing_env(ecom_env) do
      travel_to(base_time) { described_class.perform_now }
      travel_to(base_time + 2.hours) { described_class.perform_now }
      expect(invoice.reload.recurring_attempts_count).to eq(1)

      travel_to(base_time + 25.hours) { described_class.perform_now }
      travel_to(base_time + 50.hours) { described_class.perform_now }
      travel_to(base_time + 75.hours) { described_class.perform_now }
    end

    expect(invoice.reload).to have_attributes(status: 'issued', recurring_attempts_count: 3)
    expect(invoice.payment_url).to start_with('https://ecom.bcc.kz/checkout?')
    events = Array(invoice.metadata['notifications']).map { |entry| entry['event'] }
    expect(events).to include('recurring_fallback')
  end
end
