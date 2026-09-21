class Whatsapp::WebhookIngressConfigValidator
  def self.validate!(key:, value:)
    if key == Whatsapp::WebhookIngressRouter::RULES_CONFIG_KEY
      return normalize_legacy_rules(value)
    elsif key == Whatsapp::WebhookIngressRouter::TARGETS_CONFIG_KEY
      targets = value.stringify_keys
      router = Whatsapp::WebhookIngressRouter.new(payload: {}, targets: targets)
      normalized_targets = targets.to_h { |destination, _url| [destination, router.target_url!(destination)] }
      raise Whatsapp::WebhookIngressRouter::ConfigurationError unless normalized_targets == Whatsapp::WebhookIngressRouter::FORWARD_TARGET_CONTRACT

      return normalized_targets
    end

    value
  end

  def self.normalize_legacy_rules(value)
    value.to_h.each_with_object({}) do |(route_key, destinations), normalized|
      route_key = route_key.to_s
      raise Whatsapp::WebhookIngressRouter::ConfigurationError unless route_key.match?(Whatsapp::WebhookIngressRouter::ROUTE_KEY_PATTERN)

      route_destinations = Array(destinations).map(&:to_s).compact_blank.uniq
      supported_destinations = [Whatsapp::WebhookIngressRouter::LOCAL_DESTINATION] +
                               Whatsapp::WebhookIngressRouter::FORWARD_TARGET_CONTRACT.keys
      unless route_destinations.present? && (route_destinations - supported_destinations).empty?
        raise Whatsapp::WebhookIngressRouter::ConfigurationError
      end

      normalized[route_key] = route_destinations
    end
  end
  private_class_method :normalize_legacy_rules
end
