# frozen_string_literal: true

class Integrations::KaspiPay::PendingAuthStore
  PENDING_TTL_SECONDS = 600 # 10 minutes

  def initialize(account_id:)
    @account_id = account_id
  end

  def store!(process_id:, payload:)
    ciphertext = encryptor.encrypt_and_sign(payload.to_json)
    ::Redis::Alfred.setex(redis_key(process_id), ciphertext, PENDING_TTL_SECONDS)
  end

  def fetch!(process_id)
    if process_id.blank?
      raise Integrations::KaspiPay::ApiClient::ApiError.new(
        'Сессия подтверждения SMS не найдена или истекла. Запросите код заново.',
        code: 'ExpiredProcessId'
      )
    end

    ciphertext = ::Redis::Alfred.get(redis_key(process_id))
    if ciphertext.blank?
      raise Integrations::KaspiPay::ApiClient::ApiError.new(
        'Время ожидания SMS-кода истекло (10 минут). Запросите новый код.',
        code: 'ExpiredProcessId'
      )
    end

    JSON.parse(encryptor.decrypt_and_verify(ciphertext))
  rescue ActiveSupport::MessageEncryptor::InvalidMessage, JSON::ParserError
    raise Integrations::KaspiPay::ApiClient::ApiError.new(
      'Некорректная сессия подтверждения SMS. Запросите новый код.',
      code: 'InvalidPendingSession'
    )
  end

  def delete!(process_id)
    ::Redis::Alfred.delete(redis_key(process_id))
  end

  private

  def redis_key(process_id)
    "kaspi_pay:pending_auth:#{@account_id}:#{process_id}"
  end

  def encryptor
    @encryptor ||= begin
      key_len = ActiveSupport::MessageEncryptor.key_len
      secret = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base)
                                          .generate_key('kaspi_pay_pending_auth_v1', key_len)
      ActiveSupport::MessageEncryptor.new(secret)
    end
  end
end
