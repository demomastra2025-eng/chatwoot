# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /webhooks/bcc_ecom', type: :request do
  def with_billing_env(overrides)
    previous = overrides.keys.index_with { |key| ENV.fetch(key, nil) }
    overrides.each { |key, val| val.nil? ? ENV.delete(key) : ENV[key] = val }
    yield
  ensure
    previous.each { |key, val| val.nil? ? ENV.delete(key) : ENV[key] = val }
  end

  let(:secret_key) { 'bcc_webhook_secret_key_789' }
  let(:ecom_env) do
    {
      'BILLING_AUTOBILLING_ENABLED' => 'true',
      'BCC_ECOM_BASE_URL' => 'https://ecom.bcc.kz',
      'BCC_ECOM_MERCHANT_ID' => 'm1',
      'BCC_ECOM_TERMINAL_ID' => 't1',
      'BCC_ECOM_SECRET_KEY' => secret_key
    }
  end
  let(:account) { create(:account) }
  let!(:profile) do
    Accounts::ApplyPlan.new(account: account, tariff: 'text_call').call
    Billing::AccountProfile.create!(account: account, billing_enabled: true, paid_until: Date.new(2026, 11, 10))
  end
  let!(:invoice) do
    Billing::InvoiceGeneratorService.new(account: account, period_start: Date.new(2026, 11, 10), notify: false).perform
  end

  it 'rejects requests with invalid HMAC signature with 401 Unauthorized' do
    raw = { order_id: invoice.invoice_number, rrn: 'RRN-BAD', amount_minor: invoice.amount_minor, status: 'approved' }.to_json

    with_billing_env(ecom_env) do
      post '/webhooks/bcc_ecom', params: raw, headers: { 'CONTENT_TYPE' => 'application/json', 'X-BCC-Signature' => 'invalid_hmac' }
    end

    expect(response).to have_http_status(:unauthorized)
    expect(invoice.reload.status).to eq('issued')
  end

  it 'verifies HMAC, settles invoice, stores opted-in Card-on-File token, and strips card_token from raw_payload' do
    raw = {
      merchant_id: 'm1',
      order_id: invoice.invoice_number,
      rrn: 'RRN-OK-777',
      amount_minor: invoice.amount_minor,
      currency: 'KZT',
      status: 'approved',
      save_card: true,
      card_token: 'tok_saved_999',
      card_masked: '5522********8899'
    }.to_json
    sig = OpenSSL::HMAC.hexdigest('SHA256', secret_key, raw)

    with_billing_env(ecom_env) do
      post '/webhooks/bcc_ecom', params: raw, headers: { 'CONTENT_TYPE' => 'application/json', 'X-BCC-Signature' => "sha256=#{sig}" }
    end

    expect(response).to have_http_status(:ok)
    expect(invoice.reload).to have_attributes(status: 'paid', bank_reference_id: 'RRN-OK-777')
    expect(profile.reload).to have_attributes(
      paid_until: Date.new(2026, 12, 10), autopay_enabled: true,
      bcc_card_token: 'tok_saved_999', bcc_card_masked: '5522********8899'
    )
    event = Billing::PaymentEvent.find_by!(bank_reference_id: 'RRN-OK-777')
    expect(event.raw_payload.keys).not_to include('card_token')
  end

  it 'refuses to save card_token when payment is partial (needs_review) or merchant_id mismatches' do
    partial_raw = {
      merchant_id: 'm1', order_id: invoice.invoice_number, rrn: 'RRN-PARTIAL-TOK',
      amount_minor: 1000, currency: 'KZT', status: 'approved', save_card: true, card_token: 'tok_untrusted_1'
    }.to_json
    partial_sig = OpenSSL::HMAC.hexdigest('SHA256', secret_key, partial_raw)

    wrong_merchant_raw = {
      merchant_id: 'm_foreign', order_id: invoice.invoice_number, rrn: 'RRN-WRONG-MERCH',
      amount_minor: invoice.amount_minor, currency: 'KZT', status: 'approved', save_card: true, card_token: 'tok_untrusted_2'
    }.to_json
    wrong_merchant_sig = OpenSSL::HMAC.hexdigest('SHA256', secret_key, wrong_merchant_raw)

    with_billing_env(ecom_env) do
      post '/webhooks/bcc_ecom', params: partial_raw,
                                 headers: { 'CONTENT_TYPE' => 'application/json', 'X-BCC-Signature' => partial_sig }
      expect(profile.reload.bcc_card_token).to be_nil
      expect(profile.autopay_enabled).to be(false)

      post '/webhooks/bcc_ecom', params: wrong_merchant_raw,
                                 headers: { 'CONTENT_TYPE' => 'application/json', 'X-BCC-Signature' => wrong_merchant_sig }
      expect(profile.reload.bcc_card_token).to be_nil
      expect(profile.autopay_enabled).to be(false)
    end
  end
end
