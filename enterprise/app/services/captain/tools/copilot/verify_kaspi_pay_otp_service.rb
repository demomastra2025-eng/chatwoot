class Captain::Tools::Copilot::VerifyKaspiPayOtpService < Captain::Tools::Copilot::KaspiPayBaseService
  def self.name
    'verify_kaspi_pay_otp'
  end

  description 'Administrator-only step: verify the Kaspi Pay OTP and connect the merchant account. Never returns session tokens.'
  param :process_id, type: :string, desc: 'Kaspi Pay connection process ID returned by start_kaspi_pay_connection', required: true
  param :otp, type: :string, desc: 'One-time OTP code sent by Kaspi Pay. It is sensitive and will be redacted in audit logs.', required: true
  param :phone_number, type: :string, desc: 'Optional phone number used in the OTP flow', required: false
  param :default_payment_type, type: :string, desc: 'Optional default payment type. Currently only qr is supported.', required: false
  param :latitude, type: :number, desc: 'Optional POS latitude for QR creation', required: false
  param :longitude, type: :number, desc: 'Optional POS longitude for QR creation', required: false

  def execute(process_id:, otp:, phone_number: nil, default_payment_type: nil, latitude: nil, longitude: nil)
    formatted_kaspi_payload(
      kaspi_pay_operations.verify_otp(
        process_id: process_id,
        otp: otp,
        phone_number: phone_number,
        settings: parse_settings(latitude: latitude, longitude: longitude, default_payment_type: default_payment_type)
      )
    )
  end
end
