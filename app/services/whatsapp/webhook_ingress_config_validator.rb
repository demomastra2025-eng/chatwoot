class Whatsapp::WebhookIngressConfigValidator
  def self.validate!(key:, value:)
    if key == Whatsapp::WebhookIngressRouter::RULES_CONFIG_KEY
      Whatsapp::WebhookIngressRouter.new(
        payload: {}, rules: value, targets: Whatsapp::WebhookIngressRouter::FORWARD_TARGET_CONTRACT
      ).routing_enabled?
    elsif key == Whatsapp::WebhookIngressRouter::TARGETS_CONFIG_KEY &&
          value.stringify_keys != Whatsapp::WebhookIngressRouter::FORWARD_TARGET_CONTRACT
      raise Whatsapp::WebhookIngressRouter::ConfigurationError
    end

    value
  end
end
