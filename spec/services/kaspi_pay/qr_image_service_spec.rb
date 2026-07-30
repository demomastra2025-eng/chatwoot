require 'rails_helper'

RSpec.describe KaspiPay::QrImageService do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :kaspi_pay, account: account) }
  let(:payment) do
    create(
      :kaspi_pay_payment,
      account: account,
      integration_hook: hook,
      qr_original_token: 'https://qr.kaspi.kz/original-token'
    )
  end
  let(:client) { instance_double(KaspiPay::Client) }
  let(:png) { "\x89PNG\r\n\x1A\nqr-image".b }

  it 'creates an account-scoped PNG blob from the original Unified QR token' do
    allow(client).to receive(:render_qr_png).with(payment.qr_original_token).and_return(png)

    blob = described_class.new(payment: payment, client: client).create_blob!

    expect(blob.filename.to_s).to eq("kaspi-pay-#{payment.id}.png")
    expect(blob.content_type).to eq('image/png')
    expect(blob.metadata).to include('account_id' => account.id, 'kaspi_pay_payment_id' => payment.id)
    expect(blob.download).to eq(png)
  end

  it 'rejects a payment without an original Unified QR token' do
    payment.update!(qr_original_token: nil)

    expect { described_class.new(payment: payment, client: client).create_blob! }
      .to raise_error(KaspiPay::Error) { |error| expect(error.code).to eq('QR_TOKEN_MISSING') }
  end
end
