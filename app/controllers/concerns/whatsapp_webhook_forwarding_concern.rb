module WhatsappWebhookForwardingConcern
  extend ActiveSupport::Concern

  private

  def verify_forwarded_delivery!
    return unless forwarded_delivery?
    return if valid_forwarded_delivery?

    head :unauthorized
  end

  def forwarded_delivery?
    request.headers[Whatsapp::WebhookIngressRouter::FORWARDED_HEADER] == '1'
  end

  def valid_forwarded_delivery?
    destination = request.headers[Whatsapp::WebhookIngressRouter::FORWARDED_DESTINATION_HEADER].to_s
    signature = request.headers[Whatsapp::WebhookIngressRouter::FORWARDED_SIGNATURE_HEADER].to_s
    return false unless destination.match?(Whatsapp::WebhookIngressRouter::DESTINATION_PATTERN)
    return false unless signature.start_with?(Whatsapp::WebhookIngressRouter::SIGNATURE_PREFIX)
    return false unless receiver_destination_matches?(destination)

    forward_secret = GlobalConfigService.load(Whatsapp::WebhookIngressRouter::FORWARD_SECRET_CONFIG_KEY, nil).to_s
    return false if forward_secret.blank?

    expected = Whatsapp::WebhookIngressRouter.forwarded_signature(
      secret: forward_secret,
      destination: destination,
      body: meta_request_body
    )
    ActiveSupport::SecurityUtils.secure_compare(expected, signature)
  end

  def receiver_destination_matches?(destination)
    expected = GlobalConfigService.load(Whatsapp::WebhookIngressRouter::RECEIVER_DESTINATION_CONFIG_KEY, nil).to_s
    return false unless expected.match?(Whatsapp::WebhookIngressRouter::DESTINATION_PATTERN)

    ActiveSupport::SecurityUtils.secure_compare(expected, destination)
  end
end
