require 'net/http'

class Webhooks::WhatsappForwardJob < ApplicationJob
  class DeliveryError < StandardError; end

  queue_as :whatsapp_webhook_forward
  retry_on DeliveryError, wait: :polynomially_longer, attempts: 12

  def perform(payload, destination)
    payload = payload.to_h.with_indifferent_access
    router = Whatsapp::WebhookIngressRouter.new(payload: payload, rules: {})
    body = JSON.generate(payload.deep_stringify_keys)
    response = deliver(router.target_endpoint!(destination), body, destination)
    return if response.is_a?(Net::HTTPSuccess)

    raise DeliveryError, "WhatsApp webhook forwarding failed target=#{destination} status=#{response.code}"
  rescue DeliveryError
    raise
  rescue StandardError => e
    raise DeliveryError, "WhatsApp webhook forwarding failed target=#{destination} error_class=#{e.class.name}"
  end

  private

  def deliver(endpoint, body, destination)
    uri = endpoint.fetch(:uri)
    http = Net::HTTP.new(uri.host, uri.port, nil)
    http.ipaddr = endpoint.fetch(:ip_address).to_s
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 10
    http.write_timeout = 10
    http.request(forward_request(uri, body, destination))
  end

  def forward_request(uri, body, destination)
    Net::HTTP::Post.new(uri.request_uri, forward_headers(body, destination)).tap do |request|
      request.body = body
    end
  end

  def forward_headers(body, destination)
    meta_app_secret = GlobalConfigService.load('WHATSAPP_APP_SECRET', nil).to_s
    forward_secret = GlobalConfigService.load(Whatsapp::WebhookIngressRouter::FORWARD_SECRET_CONFIG_KEY, nil).to_s
    raise DeliveryError, 'WhatsApp App Secret is required for webhook forwarding' if meta_app_secret.blank?
    raise DeliveryError, 'WhatsApp webhook forward secret is required' if forward_secret.blank?

    {
      'Content-Type' => 'application/json',
      'X-Hub-Signature-256' => "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', meta_app_secret, body)}",
      Whatsapp::WebhookIngressRouter::FORWARDED_HEADER => '1',
      Whatsapp::WebhookIngressRouter::FORWARDED_DESTINATION_HEADER => destination.to_s,
      Whatsapp::WebhookIngressRouter::FORWARDED_SIGNATURE_HEADER => Whatsapp::WebhookIngressRouter.forwarded_signature(
        secret: forward_secret,
        destination: destination,
        body: body
      )
    }
  end
end
