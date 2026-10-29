# frozen_string_literal: true

class Integrations::KaspiPay::ApiClient
  class ApiError < StandardError
    attr_reader :code, :http_status, :details

    def initialize(message, code: nil, http_status: nil, details: nil)
      super(message)
      @code = code
      @http_status = http_status
      @details = details
    end
  end

  class SessionEvictedError < ApiError; end

  include Integrations::KaspiPay::HttpTransport
  include Integrations::KaspiPay::EntranceCookies
  include Integrations::KaspiPay::EntranceHelpers
  include Integrations::KaspiPay::EntranceFlow

  QRPAY_BASE_URL = 'https://qrpay.kaspi.kz'
  DEFAULT_LATITUDE = 43.20464348337589
  DEFAULT_LONGITUDE = 76.89196236411591

  def initialize(device:, session: nil, app_overrides: {})
    @device = device.stringify_keys
    @session = (session || {}).stringify_keys
    @app = build_app_config(app_overrides)
  end

  def create_qr_token(amount:, latitude: DEFAULT_LATITUDE, longitude: DEFAULT_LONGITUDE)
    payload = {
      PaymentAmount: amount.to_i,
      DeviceInterface: 'Pos',
      Latitude: latitude || DEFAULT_LATITUDE,
      Longitude: longitude || DEFAULT_LONGITUDE
    }.to_json
    data = qrpay_post("#{QRPAY_BASE_URL}/v01/qr-token/create", payload)['Data'] || {}
    format_qr_token_result(data, amount.to_i)
  end

  def qr_status(qr_operation_id:)
    body = qrpay_get("#{QRPAY_BASE_URL}/v02/kaspi-qr/status?qrOperationId=#{CGI.escape(qr_operation_id.to_s)}")
    body['Data'] || {}
  end

  def client_info(phone_10:)
    body = qrpay_get("#{QRPAY_BASE_URL}/v01/remote/client-info?phoneNumber=#{CGI.escape(phone_10.to_s)}")
    body['Data'] || {}
  end

  def create_remote_invoice(phone_10:, amount:, comment: '')
    payload = { PhoneNumber: phone_10.to_s, Amount: amount.to_i, Comment: comment.to_s.strip }.to_json
    data = qrpay_post("#{QRPAY_BASE_URL}/v01/remote/create", payload)['Data'] || {}
    {
      qr_operation_id: (data['QrOperationId'] || data['Id'])&.to_s,
      amount: data['Amount'] || amount.to_i,
      receipt_url: data['ReceiptUrl'],
      order_number: data['OrderNumber'],
      raw: data
    }
  end

  def remote_invoice_details(operation_id:)
    body = qrpay_get("#{QRPAY_BASE_URL}/v02/remote/details?operationId=#{CGI.escape(operation_id.to_s)}")
    body['Data'] || {}
  end

  def cancel_remote_invoice(operation_id:)
    payload = { qrOperationId: operation_id.to_i }.to_json
    qrpay_post("#{QRPAY_BASE_URL}/v01/remote/cancel", payload)['Data'] || {}
  end

  def refund_payment(qr_operation_id:, return_amount:)
    payload = {
      ReturnAmount: return_amount.to_i,
      QrOperationId: qr_operation_id.to_i,
      DeviceInterface: 'Pos'
    }.to_json
    qrpay_post("#{QRPAY_BASE_URL}/v01/kaspi-qr/history-pos-return", payload)['Data'] || {}
  end

  def check_session(end_date: Time.now.in_time_zone(ALMATY_TZ).strftime('%Y-%m-%d'))
    payload = { EndDate: end_date, LastTransactionDate: '', StatementPeriodCode: 0 }.to_json
    qrpay_post("#{QRPAY_BASE_URL}/v02/history/operations", payload)
    { active: true }
  rescue SessionEvictedError => e
    { active: false, evicted: true, error: e.message, code: e.code }
  rescue ApiError => e
    { active: false, evicted: false, error: e.message, code: e.code }
  end

  private

  def format_qr_token_result(data, fallback_amount)
    bare_token = data['QrToken'].to_s.strip.sub(%r{\Ahttps?://(?:qr|pay)\.kaspi\.kz/(?:pay/)?}i, '').presence
    {
      qr_operation_id: data['QrOperationId']&.to_s,
      pay_url: bare_token ? "https://pay.kaspi.kz/pay/#{bare_token}" : nil,
      unified_qr_url: bare_token ? "https://qr.kaspi.kz/#{bare_token}" : nil,
      expire_date: data['ExpireDate'],
      receipt_url: data['ReceiptUrl'],
      amount: data['Amount'] || fallback_amount,
      behavior_options: data['QrPaymentBehaviorOptions'] || {},
      raw: data
    }
  end
end
