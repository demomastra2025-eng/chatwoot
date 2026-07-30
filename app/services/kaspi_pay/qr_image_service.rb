require 'stringio'

class KaspiPay::QrImageService
  def initialize(payment:, client: nil)
    @payment = payment
    @client = client || KaspiPay::Client.new(hook: payment.integration_hook)
  end

  def create_blob!
    raise KaspiPay::Error.new('Kaspi Unified QR token is missing', code: 'QR_TOKEN_MISSING') if payment.qr_original_token.blank?

    png = client.render_qr_png(payment.qr_original_token)
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(png),
      filename: "kaspi-pay-#{payment.id}.png",
      content_type: 'image/png',
      metadata: {
        account_id: payment.account_id,
        kaspi_pay_payment_id: payment.id
      },
      identify: false
    )
  end

  private

  attr_reader :client, :payment
end
