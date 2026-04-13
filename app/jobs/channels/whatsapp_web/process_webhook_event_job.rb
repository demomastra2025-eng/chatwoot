class Channels::WhatsappWeb::ProcessWebhookEventJob < ApplicationJob
  queue_as :high

  def perform(channel_id, payload)
    channel = Channel::WhatsappWeb.find_by(id: channel_id)
    return if channel.blank?
    return if channel.inbox&.deleting?

    WhatsappWeb::IncomingEventService.new(
      channel: channel,
      payload: payload.deep_symbolize_keys
    ).perform
  rescue StandardError => e
    Rails.logger.error("[WHATSAPP WEB] Async webhook processing failed for channel #{channel_id}: #{e.message}")
    raise
  end
end
