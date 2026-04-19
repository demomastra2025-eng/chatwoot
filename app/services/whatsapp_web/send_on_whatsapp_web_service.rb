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
    Messages::StatusUpdateService.new(message, 'failed', e.message).perform
  rescue WhatsappWeb::Providers::EvolutionService::RequestError => e
    raise unless permanent_provider_error?(e)

    Messages::StatusUpdateService.new(message, 'failed', e.message).perform
  end

  def permanent_provider_error?(error)
    status = error.status.to_i
    PERMANENT_PROVIDER_STATUSES.include?(status)
  end
end
