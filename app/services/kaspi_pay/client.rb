require 'net/http'
require 'openssl'

class KaspiPay::Client
  DEFAULT_TIMEOUT = 15
  MAX_QR_PNG_BYTES = 2 * 1024 * 1024
  PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b.freeze

  def initialize(hook: nil, adapter_url: ENV.fetch('KASPI_PAY_ADAPTER_URL', nil), internal_secret: ENV.fetch('KASPI_PAY_INTERNAL_SECRET', nil))
    @hook = hook
    @adapter_url = adapter_url.to_s.delete_suffix('/')
    @internal_secret = internal_secret.to_s
  end

  def init
    post('/internal/kaspi/auth/init')
  end

  def send_phone(process_id:, phone_number:)
    post('/internal/kaspi/auth/send-phone', processId: process_id, phoneNumber: phone_number)
  end

  def verify_otp(process_id:, otp:, phone_number: nil)
    post('/internal/kaspi/auth/verify-otp', processId: process_id, otp: otp, phoneNumber: phone_number)
  end

  def refresh(hook: self.hook)
    post('/internal/kaspi/auth/refresh', session_payload(hook), {})
  end

  def create_qr(amount:, latitude: nil, longitude: nil)
    post('/internal/kaspi/qr/create', { amount: amount, latitude: latitude, longitude: longitude }.compact, session_headers)
  end

  def qr_status(operation_id)
    get('/internal/kaspi/qr/status', { qrOperationId: operation_id }, session_headers)
  end

  def render_qr_png(qr_original_token)
    ensure_configured!
    body = { qrToken: qr_original_token }.to_json
    uri = build_uri('/internal/kaspi/qr/render')
    response = perform_http(qr_render_request(uri, body), uri, body)

    validate_qr_render_response!(response)
  end

  def create_invoice(phone_number:, amount:, comment: nil)
    post('/internal/kaspi/invoice/create', { phoneNumber: phone_number, amount: amount, comment: comment }.compact, session_headers)
  end

  def client_info(phone_number)
    get('/internal/kaspi/invoice/client-info', { phoneNumber: phone_number }, session_headers)
  end

  def invoice_details(operation_id)
    get('/internal/kaspi/invoice/details', { operationId: operation_id }, session_headers)
  end

  def cancel_invoice(operation_id)
    post('/internal/kaspi/invoice/cancel', { operationId: operation_id }, session_headers)
  end

  def invoice_history
    post('/internal/kaspi/invoice/history', {}, session_headers)
  end

  def operations_history(end_date:, last_transaction_date: nil, statement_period_code: 0)
    post(
      '/internal/kaspi/history/operations',
      { endDate: end_date, lastTransactionDate: last_transaction_date, statementPeriodCode: statement_period_code }.compact,
      session_headers
    )
  end

  def operation_details(id, operation_method: 0)
    post('/internal/kaspi/history/details', { id: id, operationMethod: operation_method }, session_headers)
  end

  def create_refund(qr_operation_id:, return_amount:)
    post('/internal/kaspi/refund/create', { qrOperationId: qr_operation_id, returnAmount: return_amount }, session_headers)
  end

  private

  attr_reader :adapter_url, :hook, :internal_secret

  def qr_render_request(uri, body)
    Net::HTTP::Post.new(uri).tap do |request|
      request['Content-Type'] = 'application/json'
      request.body = body
    end
  end

  def validate_qr_render_response!(response)
    raise_qr_render_error!(response) unless response.is_a?(Net::HTTPSuccess)

    png = response.body.to_s.b
    valid_png = response['Content-Type'].to_s.start_with?('image/png') && png.start_with?(PNG_SIGNATURE)
    unless valid_png && png.bytesize <= MAX_QR_PNG_BYTES
      raise KaspiPay::Error.new('Kaspi Pay adapter returned an invalid QR image', code: 'QR_RENDER_INVALID_RESPONSE')
    end

    png
  end

  def raise_qr_render_error!(response)
    details = JSON.parse(response.body.presence || '{}')
    message = details['error'].presence || 'Kaspi Pay QR render failed'
    raise KaspiPay::Error.new(message, code: 'QR_RENDER_FAILED', details: details)
  rescue JSON::ParserError
    raise KaspiPay::Error.new('Kaspi Pay adapter returned an invalid QR render error', code: 'QR_RENDER_INVALID_RESPONSE')
  end

  def session_payload(current_hook = hook)
    secrets = current_hook&.secret_settings || {}
    {
      tokenSN: secrets['token_sn'],
      vtokenSecret: secrets['vtoken_secret'],
      profileId: secrets['profile_id'],
      organizationId: secrets['organization_id']
    }.compact
  end

  def post(path, payload = {}, headers = {})
    request(Net::HTTP::Post, path, payload, headers)
  end

  def get(path, query = {}, headers = {})
    ensure_configured!
    uri = build_uri(path)
    uri.query = Rack::Utils.build_nested_query(query) if query.present?
    req = Net::HTTP::Get.new(uri)
    headers.each { |key, value| req[key] = value }
    perform(req, uri, '')
  end

  def request(klass, path, payload, headers = {})
    ensure_configured!
    body = payload.to_json
    uri = build_uri(path)
    req = klass.new(uri)
    req['Content-Type'] = 'application/json'
    headers.each { |key, value| req[key] = value }
    req.body = body
    perform(req, uri, body)
  end

  def session_headers
    {
      'X-Token-SN' => session_payload[:tokenSN],
      'X-Vtoken-Secret' => session_payload[:vtokenSecret],
      'X-Profile-ID' => session_payload[:profileId],
      'X-Organization-ID' => session_payload[:organizationId]
    }.compact
  end

  def perform(req, uri, body)
    response = perform_http(req, uri, body)
    parsed = JSON.parse(response.body.presence || '{}')
    return parsed if response.is_a?(Net::HTTPSuccess)

    raise KaspiPay::Error.new(parsed['error'].presence || 'Kaspi Pay adapter request failed', code: 'ADAPTER_REQUEST_FAILED', details: parsed)
  rescue JSON::ParserError
    raise KaspiPay::Error.new('Kaspi Pay adapter returned invalid JSON', code: 'ADAPTER_INVALID_RESPONSE')
  end

  def perform_http(req, uri, body)
    timestamp = Time.current.to_i.to_s
    req['X-OneLink-Timestamp'] = timestamp
    req['X-OneLink-Internal-Signature'] = signature(req, uri, timestamp, body)

    Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == 'https',
      read_timeout: DEFAULT_TIMEOUT,
      open_timeout: DEFAULT_TIMEOUT
    ) do |http|
      http.request(req)
    end
  end

  def build_uri(path)
    uri = URI.parse("#{adapter_url}#{path}")
    return uri if uri.is_a?(URI::HTTP) && uri.host.present?

    raise KaspiPay::Error.new('Kaspi Pay adapter URL is invalid', code: 'ADAPTER_URL_INVALID', status: :service_unavailable)
  rescue URI::InvalidURIError
    raise KaspiPay::Error.new('Kaspi Pay adapter URL is invalid', code: 'ADAPTER_URL_INVALID', status: :service_unavailable)
  end

  def ensure_configured!
    if adapter_url.blank?
      raise KaspiPay::Error.new(
        'Kaspi Pay adapter URL is not configured',
        code: 'ADAPTER_NOT_CONFIGURED',
        status: :service_unavailable
      )
    end

    return if internal_secret.present?

    raise KaspiPay::Error.new(
      'Kaspi Pay internal secret is not configured',
      code: 'ADAPTER_SECRET_NOT_CONFIGURED',
      status: :service_unavailable
    )
  end

  def signature(req, uri, timestamp, body)
    payload = [req.method, uri.request_uri, timestamp, body].join("\n")
    OpenSSL::HMAC.hexdigest('SHA256', internal_secret, payload)
  end
end
