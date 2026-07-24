class Channels::WhatsappWeb::ProvisionJob < ApplicationJob
  queue_as :default

  def perform(channel_id)
    channel = Channel::WhatsappWeb.find_by(id: channel_id)
    return if channel.blank?

    channel.provision!
  rescue WhatsappWeb::LifecycleLock::LockAcquisitionError => e
    Rails.logger.info("[WHATSAPP WEB] Provisioning deferred for channel #{channel_id}: #{e.message}")
    raise
  rescue StandardError => e
    Rails.logger.error("[WHATSAPP WEB] Provisioning failed for channel #{channel_id}: #{e.message}")
    channel&.mark_failed!(e.message)
    raise
  end
end
