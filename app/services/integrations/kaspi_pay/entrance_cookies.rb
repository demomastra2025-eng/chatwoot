# frozen_string_literal: true

module Integrations::KaspiPay::EntranceCookies
  private

  def raise_init_error!(body)
    code = extract_entrance_error_code(body)
    msg = humanize_entrance_error(code, extract_entrance_error_message(body))
    raise Integrations::KaspiPay::ApiClient::ApiError.new(msg, code: code || 'InitFailed')
  end

  def entrance_headers(referer:, user_token:)
    ios_ver = @app[:platform_ver].to_s.tr('.', '_')
    ua = "Mozilla/5.0 (iPhone; CPU iPhone OS #{ios_ver} like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
    {
      'Accept' => 'application/json, text/plain, */*', 'Content-Type' => 'application/json', 'Accept-Language' => 'ru',
      'Origin' => Integrations::KaspiPay::EntranceFlow::ENTRANCE_BASE_URL, 'Referer' => referer,
      'Sec-Fetch-Site' => 'same-origin', 'Sec-Fetch-Mode' => 'cors', 'Sec-Fetch-Dest' => 'empty',
      'User-Agent' => ua, 'Cookie' => entrance_cookie(user_token)
    }
  end

  def entrance_cookie(user_token = nil)
    cookie = "deviceId=#{@device['device_id']}; installId=#{@device['install_id']}; is_mobile_app=true; " \
             "locale=#{@app[:locale]}; ma_bld=#{@app[:build]}; ma_platform_type=#{@app[:platform]}; " \
             "ma_platform_ver=#{@app[:platform_ver]}; ma_ver=#{@app[:version]}; " \
             "pk=#{@device['pk']}; pkTag=#{@device['pk_tag']}; xs=R:0|E:0|RH:0|N:0"
    user_token.present? ? "#{cookie}; user_token=#{user_token}" : cookie
  end

  def extract_user_token(http_response)
    Array(http_response.get_fields('set-cookie')).each do |header|
      match = header.match(/user_token=([^;]+)/)
      return match[1] if match
    end
    nil
  end

  def extract_entrance_error(body)
    return {} unless body.is_a?(Hash)

    err = body.dig('view', 'onOpenAlarm', 'error') || body['error'] || body.dig('data', 'error')
    err.is_a?(Hash) ? err : {}
  end

  def extract_entrance_error_code(body)
    extract_entrance_error(body)['code']
  end

  def extract_entrance_error_message(body)
    return nil unless body.is_a?(Hash)

    err = extract_entrance_error(body)
    err['label'].presence || err['desc'].presence || err['description'].presence || body.dig('data', 'desc').presence
  end

  def humanize_entrance_error(code, fallback_msg)
    case code
    when 'OldVersionToUpdate'
      'Kaspi Pay обновил минимальную версию мобильного приложения (OldVersionToUpdate). Обновите версию клиента в настройках интеграции.'
    when 'UserPhoneNumberDoesNotBelongToAnyOperator'
      'Kaspi отклонил номер телефона. Проверьте, что введён реальный казахстанский номер кассира (+7 7XX XXX XX XX).'
    else
      fallback_msg.presence || 'Kaspi Pay не отправил SMS-код на указанный номер. Проверьте, что номер добавлен в Kaspi Pay с ролью «Кассир».'
    end
  end
end
