class Whatsapp::WebhookIngressConfigValidator
  def self.validate!(key:, value:)
    if key == Whatsapp::WebhookIngressRouter::RULES_CONFIG_KEY
      Whatsapp::WebhookIngressRouter.new(
        payload: {}, rules: value, targets: Whatsapp::WebhookIngressRouter::FORWARD_TARGET_CONTRACT
      ).routing_enabled?
    elsif key == Whatsapp::WebhookIngressRouter::TARGETS_CONFIG_KEY
      targets = value.stringify_keys
      router = Whatsapp::WebhookIngressRouter.new(payload: {}, targets: targets)
      normalized_targets = targets.to_h { |destination, _url| [destination, router.target_url!(destination)] }
      raise Whatsapp::WebhookIngressRouter::ConfigurationError unless normalized_targets == Whatsapp::WebhookIngressRouter::FORWARD_TARGET_CONTRACT

      return normalized_targets
    end

    value
  end
end
