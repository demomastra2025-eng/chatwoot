# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::KaspiPay::PollPaymentJob do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:device) { Integrations::KaspiPay::Crypto.generate_device_identity }
  let!(:hook) do
    account.hooks.create!(
      app_id: 'kaspi_pay',
      hook_type: :account,
      status: :enabled,
      access_token: {
        'device' => device,
        'token_sn' => 'TSN_JOB_1',
        'vtoken_secret_b64' => Base64.strict_encode64('j' * 32)
      }.to_json,
      settings: { 'session_status' => 'active', 'profile_id' => '321' }
    )
  end

  it 're-enqueues itself while payment remains pending and stops once paid' do
    payment = account.kaspi_pay_payments.create!(
      hook: hook,
      payment_type: 'qr',
      status: 'pending',
      qr_operation_id: 'JOB_OP_1',
      amount: 7000,
      expires_at: 15.minutes.from_now
    )

    stub_request(:get, 'https://qrpay.kaspi.kz/v02/kaspi-qr/status?qrOperationId=JOB_OP_1')
      .to_return(
        { status: 200, headers: { 'Content-Type' => 'application/json' }, body: { StatusCode: 0, Data: { Status: 'Wait' } }.to_json },
        { status: 200, headers: { 'Content-Type' => 'application/json' }, body: { StatusCode: 0, Data: { Status: 'Processed' } }.to_json }
      )

    expect do
      described_class.perform_now(payment.id)
    end.to have_enqueued_job(described_class).with(payment.id)
    expect(payment.reload.status).to eq('pending')

    clear_enqueued_jobs
    expect do
      described_class.perform_now(payment.id)
    end.not_to have_enqueued_job(described_class)
    expect(payment.reload.status).to eq('paid')
  end

  it 'marks payment lost when MAX_POLL_ATTEMPTS is reached directly or via transient errors' do
    payment = account.kaspi_pay_payments.create!(
      hook: hook,
      payment_type: 'qr',
      status: 'pending',
      qr_operation_id: 'JOB_OP_MAX',
      amount: 5000,
      poll_attempts: described_class::MAX_POLL_ATTEMPTS - 1
    )

    stub_request(:get, 'https://qrpay.kaspi.kz/v02/kaspi-qr/status?qrOperationId=JOB_OP_MAX')
      .to_return(status: 502, headers: { 'Content-Type' => 'application/json' }, body: { Message: 'Bad gateway' }.to_json)

    described_class.perform_now(payment.id)
    expect(payment.reload.status).to eq('lost')
    expect(payment.provider_status).to eq('PollingExhausted')
  end
end
