# frozen_string_literal: true

require 'net/http'
require 'uri'

module Integrations::KaspiPay::HttpTransport
  ALMATY_TZ = 'Asia/Almaty'
  SESSION_EVICTED_CODE = -101_001
  VERSION_RESOLVER = Integrations::KaspiPay::AppVersionResolver
  QRPAY_X_SH = 'url,X-Install-ID,X-PI,X-App-Bld,X-Platform-Ver,X-Locale,X-App-Ver,X-Device-ID,X-SV,X-Time,' \
               'X-Platform-Type,X-Call,X-Kb-TokenSnMac,X-Kb-TokenSn'

  APP_ENV_MAP = {
    version: ['KASPI_PAY_APP_VERSION', VERSION_RESOLVER::FALLBACK_VERSION], build: ['KASPI_PAY_APP_BUILD', VERSION_RESOLVER::FALLBACK_BUILD],
    platform: %w[KASPI_PAY_APP_PLATFORM iOS], platform_ver: ['KASPI_PAY_APP_PLATFORM_VER', '18.4'], model: ['KASPI_PAY_APP_MODEL', 'iPhone16,2'],
    cf_network: ['KASPI_PAY_APP_CFNETWORK', 'CFNetwork/3826.400.120'], darwin: ['KASPI_PAY_APP_DARWIN', 'Darwin/24.4.0']
  }.freeze
  STATIC_APP_DEFAULTS = { locale: 'ru-RU', brand: 'Apple', device_name: 'iPhone', screen_w: '430.0', screen_h: '932.0' }.freeze

  def app_version = @app[:version]
  def app_build = @app[:build]

  private

  def build_app_config(overrides = {})
    ovr = (overrides || {}).symbolize_keys
    resolved = APP_ENV_MAP.to_h { |k, (env, fb)| [k, resolve_override(k, ovr[k]) || resolve_env_or_default(k, env, fb)] }
    STATIC_APP_DEFAULTS.merge(resolved).merge(locale: ovr[:locale].presence || 'ru-RU')
  end

  def resolve_override(key, val) = %i[version build].include?(key) ? VERSION_RESOLVER.sanitize_format(key, val) : val.presence

  def resolve_env_or_default(key, env_name, fallback)
    return VERSION_RESOLVER.sanitize_saved_version(ENV.fetch(env_name, nil)) || VERSION_RESOLVER.resolve if key == :version
    return VERSION_RESOLVER.sanitize_saved_build(ENV.fetch(env_name, nil)) || VERSION_RESOLVER.resolve_build if key == :build

    ENV[env_name].presence || fallback
  end

  def qrpay_get(url) = validate_qrpay_response!(request_json(:get, url, headers: signed_qrpay_headers(url)).last)

  def qrpay_post(url, json_body)
    headers = signed_qrpay_headers(url, body: json_body).merge('Content-Type' => 'application/json')
    validate_qrpay_response!(request_json(:post, url, headers: headers, body: json_body).last)
  end

  def validate_qrpay_response!(body)
    status_code = body['StatusCode']
    return body if status_code.nil? || status_code.to_i.zero?
    raise build_session_evicted_error(body) if status_code.to_i == SESSION_EVICTED_CODE

    msg = body['Message'].presence || body['Description'].presence || "Ошибка Kaspi Pay (код #{status_code})"
    raise Integrations::KaspiPay::ApiClient::ApiError.new(msg, code: status_code, details: body)
  end

  def build_session_evicted_error(body)
    msg = body['Message'].presence || 'Сессия кассира Kaspi Pay завершена (выполнен вход с другого устройства). Переподключите кассира по SMS.'
    Integrations::KaspiPay::ApiClient::SessionEvictedError.new(msg, code: SESSION_EVICTED_CODE)
  end

  def signed_qrpay_headers(url, body: nil)
    headers = base_qrpay_headers(*require_qrpay_session!)
    headers['X-Sign'] = Integrations::KaspiPay::Crypto.compute_x_sign(
      @device['ec_private_key'], url: url, headers: headers, x_sh: QRPAY_X_SH, body: body
    )
    headers
  end

  def require_qrpay_session!
    token_sn = @session['token_sn'].to_s
    vtoken_b64 = @session['vtoken_secret_b64'].to_s
    return [token_sn, Base64.strict_decode64(vtoken_b64)] if token_sn.present? && vtoken_b64.present?

    raise Integrations::KaspiPay::ApiClient::ApiError.new('Сессия Kaspi Pay не настроена', code: 'MissingSession')
  end

  def base_qrpay_headers(token_sn, raw_secret)
    now = Time.current
    mac = Integrations::KaspiPay::Crypto.compute_token_sn_mac(token_sn, raw_secret, time_ms: (now.to_f * 1000).to_i)
    {
      'X-Kb-TokenSn' => token_sn, 'X-PI' => @session['profile_id'].to_s, 'X-Kb-TokenSnMac' => mac,
      'X-Install-ID' => @device['install_id'], 'X-Device-ID' => @device['device_id'],
      'X-App-Ver' => @app[:version], 'X-App-Bld' => @app[:build], 'X-Platform-Type' => @app[:platform],
      'X-Platform-Ver' => @app[:platform_ver], 'X-Locale' => @app[:locale], 'X-Time' => almaty_iso_now(now),
      'X-Request-ID' => SecureRandom.uuid.upcase, 'X-Call' => 'notConnected', 'X-SV' => '2',
      'X-SH' => QRPAY_X_SH, 'User-Agent' => ua_native, 'Accept' => '*/*', 'Accept-Language' => 'ru'
    }
  end

  def request_json(method, url, headers: {}, body: nil)
    parse_and_validate_http!(perform_http_request(method, URI.parse(url), headers, body))
  rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET => e
    raise Integrations::KaspiPay::ApiClient::ApiError.new("Ошибка соединения с Kaspi Pay: #{e.class.name}", code: 'NetworkError')
  end

  def perform_http_request(method, uri, headers, body)
    http = Net::HTTP.new(uri.host, uri.port).tap { |h| h.use_ssl = (uri.scheme == 'https') }
    http.open_timeout = 8
    http.read_timeout = 15
    req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri.request_uri)
    headers.each { |k, v| req[k] = v }
    req.body = body if body
    http.request(req)
  end

  def parse_and_validate_http!(response)
    parsed = response.body.present? ? JSON.parse(response.body) : {}
    return [response, parsed] if response.is_a?(Net::HTTPSuccess)

    raise_non_success_http_error!(response, parsed)
  rescue JSON::ParserError
    raise Integrations::KaspiPay::ApiClient::ApiError.new("Некорректный JSON от Kaspi Pay (HTTP #{response&.code})", http_status: response&.code.to_i)
  end

  def raise_non_success_http_error!(response, parsed)
    body = parsed.is_a?(Hash) ? parsed : {}
    raise build_session_evicted_error(body) if body['StatusCode'].to_i == SESSION_EVICTED_CODE

    msg = body['Message'] || body['Description'] || body['error'] || "HTTP #{response.code} при обращении к Kaspi Pay"
    raise Integrations::KaspiPay::ApiClient::ApiError.new(msg.to_s, code: body['StatusCode'], http_status: response.code.to_i, details: body)
  end

  def almaty_iso_now(now = Time.current)
    t = now.in_time_zone(ALMATY_TZ)
    "#{t.strftime('%Y-%m-%dT%H:%M:%S')}.#{format('%03d', t.usec / 1000)}#{t.strftime('%z')}"
  end

  def ua_native = "Kaspi%20Pay/#{@app[:build]} #{@app[:cf_network]} #{@app[:darwin]}"
end
