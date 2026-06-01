class Channels::LinkedinPersonal::ProcessWebhookEventJob < ApplicationJob
  queue_as :high

  def perform(channel_id, payload)
    channel = Channel::LinkedinPersonal.find_by(id: channel_id)
    return if channel.blank?

    LinkedinPersonal::IncomingEventService.new(
      channel: channel,
      payload: payload.deep_symbolize_keys
    ).perform
  rescue StandardError => e
    Rails.logger.error("[LINKEDIN PERSONAL] Async webhook processing failed for channel #{channel_id}: #{e.message}")
    raise
  end
end
