class TelegramCalls::Config
  DEFAULT_BOT_USERNAME = 'onelink_calls_bot'.freeze
  OPERATOR_WORKER_KEYS = %w[worker_id api_id api_hash string_session].freeze
  OPERATOR_WORKER_ERROR = 'Telegram voice worker configuration is invalid'.freeze

  class << self
    def bot_token
      ENV['TELEGRAM_CALLS_BOT_TOKEN'].to_s.strip
    end

    def bot_username
      raw = ENV['TELEGRAM_CALLS_BOT_USERNAME'].to_s.strip.delete_prefix('@')
      raw.presence || DEFAULT_BOT_USERNAME
    end

    def webhook_secret
      ENV['TELEGRAM_CALLS_BOT_WEBHOOK_SECRET'].to_s.strip
    end

    def gateway_url
      ENV['TELEGRAM_PERSONAL_GATEWAY_URL'].to_s.strip.chomp('/')
    end

    def gateway_token
      ENV['TELEGRAM_PERSONAL_GATEWAY_TOKEN'].to_s.strip
    end

    def operator_worker
      raw = ENV.fetch('TELEGRAM_CALLS_OPERATOR_WORKER_JSON', nil)
      return nil if raw.blank?

      invalid_operator_worker! if raw.bytesize > 8192
      worker = JSON.parse(raw)
      invalid_operator_worker! unless valid_operator_worker?(worker)

      worker
    rescue JSON::ParserError, EncodingError
      invalid_operator_worker!
    end

    def callback_token
      ENV['TELEGRAM_CALLS_SOFTPHONE_CALLBACK_TOKEN'].to_s.strip.presence || gateway_token
    end

    def frontend_url
      ENV['FRONTEND_URL'].to_s.strip.chomp('/')
    end

    def internal_base_url
      ENV['TELEGRAM_CALLS_INTERNAL_BASE_URL'].to_s.strip.chomp('/').presence || frontend_url
    end

    def callback_url
      return '' if internal_base_url.blank?

      "#{internal_base_url}/internal/voice/telegram_softphone/events"
    end

    def configured?
      bot_token.present? && bot_username.present?
    end

    def voice_gateway_configured?
      gateway_url.present? && gateway_token.present?
    end

    def deep_link_for(raw_token)
      "https://t.me/#{bot_username}?start=#{raw_token}"
    end

    def conversation_url(account_id:, conversation_display_id:)
      return nil if frontend_url.blank? || account_id.blank? || conversation_display_id.blank?
      return nil unless frontend_url.start_with?('https://', 'http://')

      "#{frontend_url}/app/accounts/#{account_id}/conversations/#{conversation_display_id}"
    end

    private

    def valid_operator_worker?(worker)
      worker.is_a?(Hash) && worker.keys.sort == OPERATOR_WORKER_KEYS.sort &&
        valid_worker_id?(worker['worker_id']) &&
        valid_api_credentials?(worker) &&
        valid_string_session?(worker['string_session'])
    end

    def valid_api_credentials?(worker)
      worker['api_id'].instance_of?(Integer) && worker['api_id'].positive? &&
        worker['api_hash'].is_a?(String) && worker['api_hash'].match?(/\A[0-9a-fA-F]{32}\z/)
    end

    def valid_worker_id?(value)
      value.is_a?(String) && value.match?(/\A[a-z][a-z0-9_-]{0,63}\z/)
    end

    def valid_string_session?(value)
      value.is_a?(String) && value.bytesize.between?(1, 4096) && value.match?(/\A[A-Za-z0-9_-]+={0,2}\z/)
    end

    def invalid_operator_worker!
      raise Telephony::Error.new(
        code: 'TELEGRAM_WORKER_CONFIG_INVALID', message: OPERATOR_WORKER_ERROR, status: :service_unavailable
      ), cause: nil
    end
  end
end
