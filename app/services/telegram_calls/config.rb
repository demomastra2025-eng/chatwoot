class TelegramCalls::Config
  DEFAULT_BOT_USERNAME = 'onelink_calls_bot'.freeze

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
  end
end
