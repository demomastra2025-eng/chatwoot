# frozen_string_literal: true

class TelegramNotification::BotClient
  TELEGRAM_API_BASE = 'https://api.telegram.org'

  def self.configured?
    ENV.fetch('TELEGRAM_NOTIFICATION_BOT_TOKEN', nil).present?
  end

  def self.send_message(chat_id:, text:)
    new.send_message(chat_id: chat_id, text: text)
  end

  def send_message(chat_id:, text:)
    return false if bot_token.blank?

    uri = URI("#{TELEGRAM_API_BASE}/bot#{bot_token}/sendMessage")
    request = Net::HTTP::Post.new(uri)
    request.content_type = 'application/json'
    request.body = {
      chat_id: chat_id,
      text: text,
      disable_web_page_preview: true
    }.to_json

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) do |http|
      http.request(request)
    end

    response.is_a?(Net::HTTPSuccess)
  rescue StandardError => e
    Rails.logger.warn("Telegram notification bot reply failed: #{e.class}")
    false
  end

  private

  def bot_token
    ENV.fetch('TELEGRAM_NOTIFICATION_BOT_TOKEN', nil)
  end
end
