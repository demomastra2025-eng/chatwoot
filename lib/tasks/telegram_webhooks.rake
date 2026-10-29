module TelegramWebhookSecretBackfill
  module_function

  def run!(frontend_url)
    abort('FRONTEND_URL is required') if frontend_url.blank?

    counts = { updated: 0, failed: 0 }
    Channel::Telegram.includes(:account).find_each do |channel|
      next unless channel.account&.active?

      refresh_channel(channel, frontend_url) ? counts[:updated] += 1 : counts[:failed] += 1
    end

    puts("Telegram webhooks refreshed: updated=#{counts[:updated]} failed=#{counts[:failed]}")
    abort('One or more Telegram webhooks failed to refresh') if counts[:failed].positive?
  end

  def refresh_channel(channel, frontend_url)
    secret = channel.webhook_secret_token
    return false if secret.blank?

    response = HTTParty.post(
      "#{channel.telegram_api_url}/setWebhook",
      body: { url: "#{frontend_url}/webhooks/telegram/#{channel.bot_token}", secret_token: secret }
    )
    ok = response.success? && response.parsed_response['ok'] == true
    warn("Failed setWebhook for channel_id=#{channel.id}: HTTP #{response.code}") unless ok
    ok
  end
end

namespace :telegram do
  desc 'Refresh Telegram setWebhook with X-Telegram-Bot-Api-Secret-Token without dropping queued updates'
  task refresh_webhook_secrets: :environment do
    TelegramWebhookSecretBackfill.run!(ENV.fetch('FRONTEND_URL', '').to_s.strip)
  end
end
