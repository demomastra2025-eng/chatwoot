require 'rails_helper'

RSpec.describe KaspiPay::HistoryReconciliationService do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :kaspi_pay, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:payment) do
    create(
      :kaspi_pay_payment,
      account: account,
      integration_hook: hook,
      source: conversation,
      amount: 10_000,
      status: 'paid',
      kaspi_operation_id: '15530881826'
    )
  end
  let(:client) { instance_double(KaspiPay::Client) }

  before do
    allow(KaspiPay::Client).to receive(:new).with(hook: hook).and_return(client)
  end

  it 'marks a paid payment as refunded when operation details contain return rows' do
    allow(client).to receive(:operation_details).with('15530881826', operation_method: 0).and_return(
      'StatusCode' => 0,
      'Data' => {
        'Amount' => 10_000,
        'AvailableReturnAmount' => 0,
        'Returns' => [{ 'Amount' => 10_000, 'Date' => '2026-05-16T15:00:00+0500' }]
      }
    )

    described_class.new(payment: payment).sync!

    expect(payment.reload.status).to eq('refunded')
    expect(payment.metadata['refund_amount']).to eq(10_000)
    activity = conversation.messages.find_by(source_id: "kaspi-pay:payment:#{payment.id}:refunded")
    expect(activity).to be_present
    expect(activity.content_attributes.dig('data', 'event')).to eq('refunded')
  end

  it 'rejects non-QR or non-numeric operations before calling Kaspi' do
    payment.update!(payment_type: 'invoice', kaspi_operation_id: 'remote-123')
    allow(client).to receive(:operation_details)

    expect do
      described_class.new(payment: payment).sync!
    end.to raise_error(KaspiPay::Error) { |error| expect(error.code).to eq('PAYMENT_NOT_RECONCILABLE') }
    expect(client).not_to have_received(:operation_details)
  end
end
