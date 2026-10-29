# frozen_string_literal: true

module Integrations::KaspiPay::EntranceHelpers
  private

  def build_finish_body(process_id, now_str, public_x509_b64)
    signed_b64 = Base64.strict_encode64(
      { installId: @device['install_id'], time: now_str, auth: [{ value: '', type: 'pincode' }], userIdHash: '' }.to_json
    )
    {
      signed: { sign: Integrations::KaspiPay::Crypto.sign_data_payload(@device['ec_private_key'], signed_b64), data: signed_b64 },
      guard: { pinHash: @device['pin_hash'], x509: public_x509_b64 }, processId: process_id
    }.to_json
  end

  def build_finish_headers(url, body, now_str)
    x_sh = Integrations::KaspiPay::EntranceFlow::FINISH_X_SH
    headers = {
      'Content-Type' => 'application/json', 'Accept' => '*/*', 'Accept-Language' => 'ru', 'User-Agent' => ua_native,
      'X-Time' => now_str, 'X-Call' => 'notConnected', 'X-Platform-Type' => @app[:platform], 'X-PkTag' => @device['pk_tag'],
      'X-SU' => Integrations::KaspiPay::Crypto.compute_x_su(url), 'X-Net-Type' => 'WIFI/ETHERNET', 'X-Emulator' => '0',
      'X-Locale' => @app[:locale], 'X-SV' => '2', 'X-Request-ID' => SecureRandom.uuid.upcase, 'X-Time-Zone' => 'GMT+05:00', 'X-SH' => x_sh
    }
    headers['X-Sign'] = Integrations::KaspiPay::Crypto.compute_x_sign(
      @device['ec_private_key'], url: url, headers: headers, x_sh: x_sh, body: body
    )
    headers
  end

  def extract_finished_session!(body, ecdh_private_b64)
    token_sn = body.dig('data', 'tokenSN').presence
    unless body['success'] && token_sn
      msg = [body.dig('error', 'title'), body.dig('error', 'description')].compact_blank.join(' ')
      raise Integrations::KaspiPay::ApiClient::ApiError.new(msg.presence || 'Ошибка привязки кассира Kaspi Pay', code: 'FinishFailed')
    end
    server_x509 = body.dig('data', 'x509').presence
    raise Integrations::KaspiPay::ApiClient::ApiError.new('Kaspi не вернул ключ x509', code: 'MissingServerX509') unless server_x509

    raw_secret = Integrations::KaspiPay::Crypto.complete_ecdh(ecdh_private_b64, server_x509)
    { token_sn: token_sn, vtoken_secret_b64: Base64.strict_encode64(raw_secret), org_context: fetch_org_context(token_sn, raw_secret) }
  end

  def fetch_org_context(token_sn, raw_secret)
    org_url = "#{Integrations::KaspiPay::EntranceFlow::MTOKEN_BASE_URL}/v08/organizations/org-context-otp"
    org_payload = build_org_context_payload
    _resp, body = request_json(:post, org_url, headers: build_org_context_headers(org_url, org_payload, token_sn, raw_secret), body: org_payload)
    validate_qrpay_response!(body)
    parsed = parse_org_context(body['Data'] || {})
    return parsed if parsed['profile_id'].present?

    raise Integrations::KaspiPay::ApiClient::ApiError.new('Kaspi Pay не вернул профиль организации (profile_id)', code: 'MissingProfileId')
  end

  def build_org_context_payload
    {
      DeviceInformation: {
        SdkVersion: 'AOTP service', DeviceId: @device['device_id'], ApplicationId: 'kz.kaspi.business',
        ScreenWidth: @app[:screen_w], Model: @app[:model], ScreenHeight: @app[:screen_h], DeviceName: @app[:device_name],
        VersionName: @app[:version], BuildRelease: "#{@app[:platform]} #{@app[:platform_ver]}", Brand: @app[:brand],
        Board: @app[:platform_ver], Platform: @app[:platform], Product: 'Kaspi Pay',
        frontCameraAvailable: true, VersionCode: @app[:build], InstallId: @device['install_id']
      },
      OrganizationId: 0
    }.to_json
  end

  def build_org_context_headers(url, body, token_sn, raw_secret)
    now = Time.current
    mac = Integrations::KaspiPay::Crypto.compute_token_sn_mac(token_sn, raw_secret, time_ms: (now.to_f * 1000).to_i)
    x_sh = Integrations::KaspiPay::EntranceFlow::ORG_X_SH
    headers = {
      'Content-Type' => 'application/json', 'Accept' => '*/*', 'Accept-Language' => 'ru', 'User-Agent' => ua_native,
      'X-Kb-TokenSn' => token_sn, 'X-Kb-TokenSnMac' => mac,
      'X-Install-ID' => @device['install_id'], 'X-App-Ver' => @app[:version], 'X-App-Bld' => @app[:build],
      'X-Locale' => @app[:locale], 'X-Call' => 'notConnected', 'X-Time' => almaty_iso_now(now), 'X-S' => 'R:0|E:0|RH:0|N:0',
      'X-SV' => '2', 'X-Kb-Client-Ip' => '192.168.1.96', 'X-PkTag' => @device['pk_tag'],
      'X-SU' => Integrations::KaspiPay::Crypto.compute_x_su(url), 'X-SH' => x_sh, 'X-Request-ID' => SecureRandom.uuid.upcase
    }
    headers['X-Sign'] = Integrations::KaspiPay::Crypto.compute_x_sign(
      @device['ec_private_key'], url: url, headers: headers, x_sh: x_sh, body: body
    )
    headers
  end

  def parse_org_context(data)
    cur = data['Current'] || {}
    orgs = Array(data['Organizations']).map do |o|
      { 'profile_id' => o['ProfileId'], 'organization_name' => o['OrganizationName'],
        'organization_id' => o['OrganizationId'], 'organization_bin' => o['OrganizationIdn'] }
    end
    { 'profile_id' => cur['ProfileId'], 'organization_name' => cur['OrganizationName'], 'organization_id' => cur['OrganizationId'],
      'organization_bin' => cur['OrganizationIdn'], 'is_cashier' => cur['IsCashier'], 'user_id' => data['UserId'], 'organizations' => orgs }
  end
end
