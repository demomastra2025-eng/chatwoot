class Channels::VkCommunity::ProcessWebhookEventJob < ApplicationJob
  queue_as :high

  def perform(channel_id, payload)
    channel = Channel::VkCommunity.find_by(id: channel_id)
    return if channel.blank?

    VkCommunity::IncomingEventService.new(
      channel: channel,
      payload: payload.deep_symbolize_keys
    ).perform
  rescue StandardError => e
    Rails.logger.error("[VK COMMUNITY] Async webhook processing failed for channel #{channel_id}: #{e.message}")
    raise
  end
end
