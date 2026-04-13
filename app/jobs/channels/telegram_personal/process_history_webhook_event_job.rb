class Channels::TelegramPersonal::ProcessHistoryWebhookEventJob < ApplicationJob
  queue_as :telegram_personal_history

  def perform(channel_id, payload)
    channel = Channel::TelegramPersonal.find_by(id: channel_id)
    return if channel.blank?

    Current.with_runtime_events_suppressed do
      TelegramPersonal::IncomingEventService.new(
        channel: channel,
        payload: payload.deep_symbolize_keys
      ).perform
    end
  rescue StandardError => e
    Rails.logger.error("[TELEGRAM PERSONAL] Async history webhook processing failed for channel #{channel_id}: #{e.message}")
    raise
  end
end
