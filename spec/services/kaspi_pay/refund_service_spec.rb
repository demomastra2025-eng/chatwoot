require 'rails_helper'

RSpec.describe KaspiPay::RefundService do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :kaspi_pay, account: account) }
  let(:payment) do
    create(
      :kaspi_pay_payment,
      account: account,
      integration_hook: hook,
      amount: 10_000,
      status: 'paid',
      kaspi_operation_id: '15530881826'
    )
  end
  let(:client) { instance_double(KaspiPay::Client) }

  before do
    allow(KaspiPay::Client).to receive(:new).with(hook: hook).and_return(client)
  end

  it 'records a full refund locally after Kaspi accepts it' do
    allow(client).to receive(:create_refund).with(qr_operation_id: '15530881826', return_amount: 10_000).and_return(
      'StatusCode' => 0,
      'Data' => { 'Status' => 'Returned' }
    )

    described_class.new(payment: payment, return_amount: 10_000).refund!

    expect(payment.reload.status).to eq('refunded')
    expect(payment.failed_at).to be_present
    expect(payment.metadata['refund_amount']).to eq(10_000)
    expect(payment.metadata['last_refund_response']).to include('Status' => 'Returned')
  end

  it 'keeps a partial refund paid and stores the cumulative refund amount' do
    payment.update!(metadata: { 'refund_amount' => 2_000 })
    allow(client).to receive(:create_refund).with(qr_operation_id: '15530881826', return_amount: 3_000).and_return(
      'StatusCode' => 0,
      'Data' => { 'Status' => 'PartiallyReturned' }
    )

    described_class.new(payment: payment, return_amount: 3_000).refund!

    expect(payment.reload.status).to eq('paid')
    expect(payment.metadata['refund_amount']).to eq(5_000)
  end

  it 'rejects refunds for non-paid payments without calling Kaspi' do
    payment.update!(status: 'pending')
    allow(client).to receive(:create_refund)

    expect do
      described_class.new(payment: payment, return_amount: 1_000).refund!
    end.to raise_error(KaspiPay::Error) { |error| expect(error.code).to eq('PAYMENT_NOT_REFUNDABLE') }
    expect(client).not_to have_received(:create_refund)
  end

  it 'rejects refund amounts above the remaining refundable amount without calling Kaspi' do
    payment.update!(metadata: { 'refund_amount' => 8_000 })
    allow(client).to receive(:create_refund)

    expect do
      described_class.new(payment: payment, return_amount: 3_000).refund!
    end.to raise_error(KaspiPay::Error) { |error| expect(error.code).to eq('REFUND_AMOUNT_EXCEEDS_REMAINING') }
    expect(client).not_to have_received(:create_refund)
  end

  it 'rejects invoice refunds because the configured provider endpoint requires QR operation id' do
    payment.update!(payment_type: 'invoice')
    allow(client).to receive(:create_refund)

    expect do
      described_class.new(payment: payment, return_amount: 1_000).refund!
    end.to raise_error(KaspiPay::Error) { |error| expect(error.code).to eq('PAYMENT_NOT_REFUNDABLE') }
    expect(client).not_to have_received(:create_refund)
  end
end
