class Channels::WhatsappWeb::ProvisionJob < ApplicationJob
  queue_as :default

  def perform(channel_id)
    channel = Channel::WhatsappWeb.find_by(id: channel_id)
    return if channel.blank?

    channel.provider_service.provision!
  rescue StandardError => e
    Rails.logger.error("[WHATSAPP WEB] Provisioning failed for channel #{channel_id}: #{e.message}")
    channel&.mark_failed!(e.message)
    raise
  end
end
