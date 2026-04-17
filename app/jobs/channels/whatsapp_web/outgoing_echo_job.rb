class Channels::WhatsappWeb::OutgoingEchoJob < ApplicationJob
  queue_as :whatsappweb_echo

  retry_on ActiveRecord::ConnectionTimeoutError, wait: 3.seconds, attempts: 10
  retry_on ActiveRecord::Deadlocked, wait: 2.seconds, attempts: 8

  def perform(channel_id, params = {})
    channel = Channel::WhatsappWeb.find_by(id: channel_id)
    return if channel.blank? || channel.inbox.blank?
    return unless channel.account.active?

    WhatsappWeb::IncomingMessageService.new(
      inbox: channel.inbox,
      params: params.deep_symbolize_keys,
      outgoing_echo: true
    ).perform
  rescue StandardError => e
    Rails.logger.error("[WHATSAPP WEB] Outgoing echo failed for channel #{channel_id}: #{e.message}")
    raise
  end
end
