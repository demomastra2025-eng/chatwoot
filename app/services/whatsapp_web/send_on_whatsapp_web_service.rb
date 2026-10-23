class WhatsappWeb::SendOnWhatsappWebService < Base::SendOnChannelService
  PERMANENT_PROVIDER_STATUSES = [400, 404, 410, 422].freeze

  private

  def channel_class
    Channel::WhatsappWeb
  end

  def perform_reply
    message_id = channel.send_message(message)
    message.update!(source_id: message_id) if message_id.present?
  rescue WhatsappWeb::Providers::EvolutionService::UnroutableRecipientError => e
    fail_message!(e)
  rescue WhatsappWeb::Providers::EvolutionService::RequestError => e
    raise unless permanent_provider_error?(e)

    fail_message!(e)
  end

  def fail_message!(error)
    log_failure(error)
    Messages::StatusUpdateService.new(message, 'failed', WhatsappWeb::DeliveryFailureReason.reason_for(error, channel: channel)).perform
  end

  # The operator sees the short Russian reason; the technical detail stays in the logs (long digit runs are masked).
  def log_failure(error)
    status = error.try(:status)
    detail = (error.try(:error_details) || error.message).to_s.gsub(/\d{9,}/, '[number]').truncate(500)
    Rails.logger.warn(
      "[WHATSAPP WEB] Outbound message #{message.id} failed channel=#{channel.id} conversation=#{message.conversation_id} " \
      "#{error.class.name} status=#{status.inspect} detail=#{detail}"
    )
  end

  def permanent_provider_error?(error)
    status = error.status.to_i
    PERMANENT_PROVIDER_STATUSES.include?(status)
  end
end
