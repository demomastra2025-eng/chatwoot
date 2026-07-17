require 'rails_helper'

RSpec.describe KaspiPay::InvoiceCancellationService do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :kaspi_pay, account: account) }
  let(:payment) do
    create(:kaspi_pay_payment, account: account, integration_hook: hook, payment_type: 'invoice', kaspi_operation_id: 'invoice-1')
  end
  let(:client) { instance_double(KaspiPay::Client) }

  before do
    allow(client).to receive(:cancel_invoice).with('invoice-1').and_return('StatusCode' => 0, 'Data' => { 'Status' => 'Cancelled' })
    allow(KaspiPay::ConversationTimelineService).to receive(:new).and_return(instance_double(KaspiPay::ConversationTimelineService,
                                                                                             record_status!: true))
  end

  it 'cancels a pending invoice and records the provider response' do
    result = described_class.new(payment: payment, client: client).cancel!

    expect(result).to be_persisted
    expect(result.status).to eq('cancelled')
    expect(result.metadata['cancel_response']).to include('StatusCode' => 0)
    expect(result.failed_at).to be_present
  end

  it 'rejects cancellation for QR payments' do
    payment.update!(payment_type: 'qr')

    expect { described_class.new(payment: payment, client: client).cancel! }
      .to raise_error(KaspiPay::Error) { |error| expect(error.code).to eq('PAYMENT_NOT_INVOICE') }
    expect(client).not_to have_received(:cancel_invoice)
  end
end
