class Channels::TelegramPersonal::ProcessWebhookEventJob < ApplicationJob
  queue_as :telegram_personal_inbound

  def perform(channel_id, payload)
    channel = Channel::TelegramPersonal.find_by(id: channel_id)
    return if channel.blank?

    TelegramPersonal::IncomingEventService.new(
      channel: channel,
      payload: payload.deep_symbolize_keys
    ).perform
  rescue StandardError => e
    Rails.logger.error("[TELEGRAM PERSONAL] Async webhook processing failed for channel #{channel_id}: #{e.message}")
    raise
  end
end
