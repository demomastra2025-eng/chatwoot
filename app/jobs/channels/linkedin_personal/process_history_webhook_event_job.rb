class Channels::LinkedinPersonal::ProcessHistoryWebhookEventJob < ApplicationJob
  queue_as :linkedin_personal_history

  def perform(channel_id, payload)
    channel = Channel::LinkedinPersonal.find_by(id: channel_id)
    return if channel.blank?

    Current.with_runtime_events_suppressed do
      LinkedinPersonal::IncomingEventService.new(
        channel: channel,
        payload: payload.deep_symbolize_keys
      ).perform
    end
  rescue StandardError => e
    Rails.logger.error("[LINKEDIN PERSONAL] Async history webhook processing failed for channel #{channel_id}: #{e.message}")
    raise
  end
end
