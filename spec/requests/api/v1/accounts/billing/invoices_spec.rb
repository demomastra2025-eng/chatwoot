# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Account Billing Invoices API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:invoice) do
    Accounts::ApplyPlan.new(account: account, tariff: 'text_call').call
    Billing::AccountProfile.create!(
      account: account,
      billing_enabled: true,
      paid_until: Date.new(2026, 11, 20),
      payment_overdue_banner: true,
      overdue_invoice_number: 'OL-202611-0001-01'
    )
    Billing::InvoiceGeneratorService.new(account: account, period_start: Date.new(2026, 11, 20), notify: false).perform
  end

  it 'allows clinic administrator to list invoices, view details, and download PDF' do
    target_invoice = invoice
    auth_headers = admin.create_new_auth_token

    get "/api/v1/accounts/#{account.id}/billing/invoices", headers: auth_headers, as: :json
    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.dig('meta', 'payment_overdue_banner')).to be(true)
    expect(body['payload'].first['invoice_number']).to eq(target_invoice.invoice_number)

    get "/api/v1/accounts/#{account.id}/billing/invoices/#{target_invoice.id}", headers: auth_headers, as: :json
    expect(response).to have_http_status(:ok)

    get "/api/v1/accounts/#{account.id}/billing/invoices/#{target_invoice.id}/pdf", headers: auth_headers
    expect(response).to have_http_status(:found)
  end

  it 'denies non-admin agents from accessing account billing invoices' do
    get "/api/v1/accounts/#{account.id}/billing/invoices", headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
  end
end
