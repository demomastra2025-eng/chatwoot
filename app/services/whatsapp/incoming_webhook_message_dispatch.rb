class Whatsapp::IncomingWebhookMessageDispatch
  pattr_initialize [:channel!, :params!, :outgoing_echo, { prepared_attachment: nil }]

  def perform
    return Whatsapp::IncomingMessageService.new(inbox: channel.inbox, params: params).perform unless cloud?

    options = { inbox: channel.inbox, params: params, require_prepared_attachment: true }
    options[:outgoing_echo] = true if outgoing_echo
    options[:prepared_attachment] = prepared_attachment if prepared_attachment.present?
    Whatsapp::IncomingMessageWhatsappCloudService.new(**options).perform
  end

  private

  def cloud?
    channel.provider == 'whatsapp_cloud'
  end
end
