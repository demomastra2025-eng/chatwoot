require 'ipaddr'
require 'socket'

class Whatsapp::WebhookIngressRouter
  class ConfigurationError < StandardError; end

  LOCAL_DESTINATION = 'prod'.freeze
  RULES_CONFIG_KEY = 'WHATSAPP_WEBHOOK_ROUTING_RULES'.freeze
  TARGETS_CONFIG_KEY = 'WHATSAPP_WEBHOOK_FORWARD_TARGETS'.freeze
  FORWARD_SECRET_CONFIG_KEY = 'WHATSAPP_WEBHOOK_FORWARD_SECRET'.freeze
  RECEIVER_DESTINATION_CONFIG_KEY = 'WHATSAPP_WEBHOOK_RECEIVER_DESTINATION'.freeze
  FORWARDED_HEADER = 'X-OneLink-Webhook-Forwarded'.freeze
  FORWARDED_DESTINATION_HEADER = 'X-OneLink-Webhook-Destination'.freeze
  FORWARDED_SIGNATURE_HEADER = 'X-OneLink-Webhook-Forwarded-Signature'.freeze
  SIGNATURE_PREFIX = 'sha256='.freeze
  ROUTE_KEY_PATTERN = /\A\d+(?::\d+)?\z/
  DESTINATION_PATTERN = /\A[a-z][a-z0-9_-]*\z/
  FORWARD_TARGET_CONTRACT = {
    'dev' => 'https://dev.one-link.kz/webhooks/whatsapp',
    'widget' => 'https://widget.one-link.kz/webhooks/meta/whatsapp'
  }.freeze
  DISALLOWED_IP_RANGES = %w[
    0.0.0.0/8
    10.0.0.0/8
    100.64.0.0/10
    127.0.0.0/8
    169.254.0.0/16
    172.16.0.0/12
    192.0.0.0/24
    192.0.2.0/24
    192.168.0.0/16
    198.18.0.0/15
    198.51.100.0/24
    203.0.113.0/24
    224.0.0.0/4
    240.0.0.0/4
    ::/128 ::1/128 ::/96 ::ffff:0:0/96
    fc00::/7 fe80::/10 ff00::/8
  ].map { |range| IPAddr.new(range) }.freeze

  def self.forwarded_signature(secret:, destination:, body:)
    signed_payload = "#{destination}\n#{body}"
    "#{SIGNATURE_PREFIX}#{OpenSSL::HMAC.hexdigest('SHA256', secret.to_s, signed_payload)}"
  end

  def initialize(payload:, rules: nil, targets: nil, route_relation: WhatsappWebhookRoute)
    @payload = payload.to_h.with_indifferent_access
    @raw_rules = rules.nil? ? GlobalConfigService.load(RULES_CONFIG_KEY, '{}') : rules
    @raw_targets = targets.nil? ? GlobalConfigService.load(TARGETS_CONFIG_KEY, '{}') : targets
    @route_relation = route_relation
  end

  def destinations
    configured_destinations = registry_route_destinations.presence || exact_route_destinations || waba_route_destinations
    normalize_destinations(configured_destinations.presence || [LOCAL_DESTINATION])
  end

  def routing_enabled? = registry_route_destinations.present? || routing_rules.present?

  def target_url!(destination)
    destination = destination.to_s
    raise ConfigurationError, 'Production webhook destination is processed locally' if destination == LOCAL_DESTINATION

    target_urls.fetch(destination) do
      raise ConfigurationError, "Missing WhatsApp webhook forward target: #{destination}"
    end
  end

  def target_endpoint!(destination)
    uri = URI.parse(target_url!(destination))
    addresses = resolved_ip_addresses(uri.host)
    raise ConfigurationError, "WhatsApp webhook forward target could not be resolved: #{destination}" if addresses.empty?
    if addresses.any? { |address| DISALLOWED_IP_RANGES.any? { |range| range.include?(address) } }
      raise ConfigurationError, "WhatsApp webhook forward target resolved to a disallowed address: #{destination}"
    end

    { uri: uri, ip_address: addresses.first }
  rescue SocketError
    raise ConfigurationError, "WhatsApp webhook forward target could not be resolved: #{destination}"
  end

  private

  def registry_route_destinations
    if phone_number_id.present?
      remote_destinations = registry_exact_route_destinations
      return remote_destinations unless remote_destinations.present? && local_prod_owner_exists?

      Rails.logger.error('[WHATSAPP] Remote webhook route conflicts with a local PROD owner; processing locally')
      return [LOCAL_DESTINATION]
    end

    registry_waba_route_destinations
  end

  def local_prod_owner_exists?
    @route_relation.local_prod_owner_exists?(waba_id, phone_number_id)
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.error("[WHATSAPP] Local PROD ownership lookup failed; processing locally error_class=#{e.class.name}")
    true
  end

  def registry_exact_route_destinations
    return [] if waba_id.blank? || phone_number_id.blank?

    @registry_exact_route_destinations ||= @route_relation.for_exact_route(waba_id, phone_number_id).distinct.pluck(:destination)
  rescue ActiveRecord::ActiveRecordError => e
    log_registry_fallback(e)
    []
  end

  def registry_waba_route_destinations
    return [] if waba_id.blank?

    @registry_waba_route_destinations ||= @route_relation.for_waba(waba_id).distinct.pluck(:destination)
  rescue ActiveRecord::ActiveRecordError => e
    log_registry_fallback(e)
    []
  end

  def log_registry_fallback(error)
    Rails.logger.error("[WHATSAPP] Webhook route registry lookup failed; using configured/local fallback error_class=#{error.class.name}")
  end

  def exact_route_destinations
    return if waba_id.blank? || phone_number_id.blank?

    routing_rules["#{waba_id}:#{phone_number_id}"]
  end

  def waba_route_destinations
    return if waba_id.blank?

    routing_rules[waba_id]
  end

  def waba_id
    @waba_id ||= @payload.dig(:entry, 0, :id).to_s.presence
  end

  def phone_number_id
    return @phone_number_id if defined?(@phone_number_id)

    phone_ids = Array(@payload[:entry]).flat_map do |entry|
      Array(entry.to_h.with_indifferent_access[:changes]).filter_map do |change|
        change.to_h.with_indifferent_access.dig(:value, :metadata, :phone_number_id).to_s.presence
      end
    end.uniq
    @phone_number_id = phone_ids.one? ? phone_ids.first : nil
  end

  def routing_rules
    @routing_rules ||= parse_object(@raw_rules, RULES_CONFIG_KEY).each_with_object({}) do |(route_key, destinations), result|
      route_key = route_key.to_s
      raise ConfigurationError, "Invalid WhatsApp webhook route key: #{route_key}" unless route_key.match?(ROUTE_KEY_PATTERN)

      result[route_key] = normalize_destinations(destinations)
    end
  end

  def target_urls
    configured_targets = FORWARD_TARGET_CONTRACT.merge(parse_object(@raw_targets, TARGETS_CONFIG_KEY).stringify_keys)
    @target_urls ||= configured_targets.each_with_object({}) do |(destination, url), result|
      destination = destination.to_s
      validate_destination_name!(destination)
      result[destination] = validate_target_url!(destination, url)
    end
  end

  def normalize_destinations(value)
    destinations = Array(value).map(&:to_s).compact_blank.uniq
    raise ConfigurationError, 'WhatsApp webhook route must have at least one destination' if destinations.empty?

    destinations.each do |destination|
      validate_destination_name!(destination)
      target_url!(destination) unless destination == LOCAL_DESTINATION
    end
    destinations
  end

  def validate_destination_name!(destination)
    return if destination.match?(DESTINATION_PATTERN)

    raise ConfigurationError, "Invalid WhatsApp webhook destination: #{destination}"
  end

  def validate_target_url!(destination, value)
    uri = URI.parse(value.to_s)
    expected_url = FORWARD_TARGET_CONTRACT[destination]
    valid = expected_url.present? && uri.is_a?(URI::HTTPS) && uri.to_s == expected_url
    raise ConfigurationError, "Invalid canonical HTTPS URL for WhatsApp webhook destination: #{destination}" unless valid

    uri.to_s
  rescue URI::InvalidURIError
    raise ConfigurationError, "Invalid canonical HTTPS URL for WhatsApp webhook destination: #{destination}"
  end

  def resolved_ip_addresses(host)
    Addrinfo.getaddrinfo(host, nil, Socket::AF_UNSPEC, Socket::SOCK_STREAM)
            .filter_map { |addrinfo| parse_ip_address(addrinfo.ip_address) }
            .uniq
  end

  def parse_ip_address(value)
    IPAddr.new(value.to_s)
  rescue IPAddr::InvalidAddressError
    nil
  end

  def parse_object(value, config_key)
    parsed = value.is_a?(String) ? JSON.parse(value.presence || '{}') : value
    return parsed.to_h if parsed.respond_to?(:to_h)

    raise ConfigurationError, "#{config_key} must be a JSON object"
  rescue JSON::ParserError
    raise ConfigurationError, "#{config_key} must be valid JSON"
  end
end
