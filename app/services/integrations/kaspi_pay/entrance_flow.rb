# frozen_string_literal: true

module Integrations::KaspiPay::EntranceFlow
  ENTRANCE_BASE_URL = 'https://entrance-pay.kaspi.kz'
  MTOKEN_BASE_URL = 'https://mtoken.kaspi.kz'
  FINISH_X_SH = 'url,X-Time-Zone,X-Request-ID,X-Net-Type,X-Emulator,X-Call,X-Platform-Type,X-Locale,X-Time,X-SV'
  ORG_X_SH = 'url,X-Kb-Client-Ip,X-Time,X-App-Ver,X-SV,X-Locale,X-App-Bld,X-Install-ID,X-Kb-TokenSn,X-S,X-Kb-TokenSnMac,X-Call'
  VIDEO_VERIFICATION_CODES = %w[UniversalKaspiIdTakePhoto ViewKaspiIdTakePhoto].freeze

  def auth_init
    resp, body = request_json(:post, "#{ENTRANCE_BASE_URL}/api/v1/entrance/step",
                              headers: entrance_headers(referer: init_referer, user_token: nil), body: init_payload_json)
    safe_body = body.is_a?(Hash) ? body : {}
    process_id = safe_body.dig('meta', 'pId').presence
    raise_init_error!(safe_body) if init_failed?(safe_body, process_id)

    { process_id: process_id, user_token: extract_user_token(resp), view: safe_body.dig('view', 'code'), body: safe_body }
  end

  def auth_send_phone(process_id:, phone_10:, user_token: nil)
    payload = { meta: { pId: process_id, sn: 'EnterPhoneNumber' }, data: { phoneNumber: phone_10 }, actType: 'Success' }.to_json
    resp, body = request_json(:post, "#{ENTRANCE_BASE_URL}/api/v1/entrance/step",
                              headers: entrance_headers(referer: step_referer(process_id), user_token: user_token), body: payload)
    validate_phone_step!(body)
    { process_id: process_id, user_token: extract_user_token(resp) || user_token, desc: body.dig('data', 'desc'), view: body.dig('view', 'code') }
  end

  def auth_verify_otp_and_finish(process_id:, otp:, user_token: nil)
    payload = { meta: { pId: process_id, sn: 'ViewEnterOtp' }, data: { userOtp: otp.to_s.strip, inputType: 'auto' }, actType: 'Success' }.to_json
    _resp, body = request_json(:post, "#{ENTRANCE_BASE_URL}/api/v1/entrance/step",
                               headers: entrance_headers(referer: step_referer(process_id), user_token: user_token), body: payload)
    validate_otp_step!(body)
    finish_device_registration(process_id: process_id)
  end

  private

  def init_failed?(body, process_id)
    process_id.blank? ||
      ActiveModel::Type::Boolean.new.cast(body['isClosed']) ||
      extract_entrance_error_code(body).present?
  end

  def init_referer
    "#{ENTRANCE_BASE_URL}/process/entrance/?auth=2&appBuild=#{@app[:build]}&appVersion=#{@app[:version]}" \
      "&platformVersion=#{@app[:platform_ver]}&platformType=IOS&deviceBrand=#{@app[:brand]}&deviceModel=#{@app[:model]}" \
      "&deviceId=#{@device['device_id']}&installId=#{@device['install_id']}&frontCameraAvailable=true&sf=registration&pc=KPEntrance&noPass=0"
  end

  def step_referer(process_id)
    "#{ENTRANCE_BASE_URL}/process/universal-enter-phone-number?pId=#{process_id}&firstPage=KPUniversalEnterPhoneNumber"
  end

  def init_payload_json
    {
      data: {}, actType: 'Success',
      Data: {
        auth: '2', appBuild: @app[:build], appVersion: @app[:version], platformVersion: @app[:platform_ver],
        platformType: 'IOS', deviceBrand: @app[:brand], deviceModel: @app[:model], deviceId: @device['device_id'],
        installId: @device['install_id'], frontCameraAvailable: 'true', sf: 'registration', pc: 'KPEntrance', noPass: '0'
      }
    }.to_json
  end

  def validate_phone_step!(body)
    view_code = body.dig('view', 'code')
    if view_code == 'KPEnterLoginPassword' || body.dig('meta', 'sn') == 'ViewEnterLoginPassword'
      raise Integrations::KaspiPay::ApiClient::ApiError.new(
        'Этот номер привязан к аккаунту руководителя/ИП с паролем (потребуется видеоверификация Kaspi ID). ' \
        'Добавьте отдельный номер сотрудника с ролью «Кассир» в приложении Kaspi Pay (Профиль → Сотрудники) и укажите номер кассира.',
        code: 'OwnerAccountPasswordRequired'
      )
    end
    return if view_code == 'EnterOtp'

    err_code = extract_entrance_error_code(body)
    raise Integrations::KaspiPay::ApiClient::ApiError.new(
      humanize_entrance_error(err_code, extract_entrance_error_message(body)), code: err_code || view_code || 'SmsNotSent'
    )
  end

  def validate_otp_step!(body)
    view_code = body.dig('view', 'code')
    if VIDEO_VERIFICATION_CODES.include?(view_code) || VIDEO_VERIFICATION_CODES.include?(body.dig('meta', 'sn'))
      raise Integrations::KaspiPay::ApiClient::ApiError.new(
        'Kaspi запросил видеоверификацию Kaspi ID. Убедитесь, что указан номер сотрудника с ролью «Кассир» ' \
        'и что владелец номера уже зарегистрирован в обычном приложении Kaspi.kz.',
        code: 'KaspiIdVideoRequired'
      )
    end
    return if body.dig('data', 'type') == 'kpDeviceRegistration' || view_code == 'KPMobileCall'

    err_msg = extract_entrance_error_message(body) || 'Неверный SMS-код или сессия подтверждения истекла'
    raise Integrations::KaspiPay::ApiClient::ApiError.new(err_msg, code: extract_entrance_error_code(body) || 'OtpRejected')
  end

  def finish_device_registration(process_id:)
    ecdh = Integrations::KaspiPay::Crypto.generate_ecdh_keypair
    now_str = almaty_iso_now
    finish_url = "#{ENTRANCE_BASE_URL}/api/v1/kpentrance/finish"
    finish_body = build_finish_body(process_id, now_str, ecdh[:public_x509_b64])
    _resp, body = request_json(:post, finish_url, headers: build_finish_headers(finish_url, finish_body, now_str), body: finish_body)
    extract_finished_session!(body, ecdh[:private_key_b64])
  end
end
