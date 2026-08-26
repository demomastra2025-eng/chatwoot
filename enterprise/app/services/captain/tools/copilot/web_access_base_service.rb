# frozen_string_literal: true

require 'ipaddr'
require 'uri'

class Captain::Tools::Copilot::WebAccessBaseService < Captain::Tools::Copilot::BaseAccountTool
  private

  def runtime_preferences
    account.captain_preferences[:runtime].to_h.stringify_keys
  end

  def ensure_firecrawl_configured!
    return if Captain::Tools::FirecrawlService.configured?

    raise ArgumentError, 'Firecrawl is not configured'
  end

  def ensure_web_tool_enabled!(tool_id)
    return if Captain::ToolAccess.per_assistant_web_tool_enabled?(assistant, tool_id)

    raise ArgumentError, 'Web capability is disabled for this assistant'
  end

  def firecrawl
    @firecrawl ||= Captain::Tools::FirecrawlService.new
  end

  def parsed_firecrawl_response(response)
    if response.respond_to?(:success?) && !response.success?
      raise ArgumentError, "Firecrawl request failed with HTTP #{response.code}"
    end

    parsed = response.respond_to?(:parsed_response) ? response.parsed_response : response
    parsed = JSON.parse(parsed) if parsed.is_a?(String)
    parsed = parsed.to_h if parsed.respond_to?(:to_h)
    raise ArgumentError, 'Firecrawl returned an invalid response' unless parsed.is_a?(Hash)

    parsed = parsed.stringify_keys

    success = parsed.key?('success') ? ActiveModel::Type::Boolean.new.cast(parsed['success']) : true
    raise ArgumentError, firecrawl_error_message(parsed) unless success

    parsed
  rescue JSON::ParserError
    raise ArgumentError, 'Firecrawl returned an invalid response'
  end

  def firecrawl_error_message(parsed)
    parsed['error'].presence || parsed['message'].presence || 'Firecrawl request failed'
  end

  def validate_public_url!(url)
    uri = URI.parse(url.to_s.strip)
    raise ArgumentError, 'URL must use http or https' unless %w[http https].include?(uri.scheme)
    raise ArgumentError, 'URL host is required' if uri.host.blank?
    raise ArgumentError, 'Local and private network URLs are not allowed' if private_host?(uri.host)
    raise ArgumentError, 'Domain is blocked by Captain web access policy' if blocked_domain?(uri.host)
    raise ArgumentError, 'Domain is not allowed by Captain web access policy' unless allowed_domain?(uri.host)

    uri
  rescue URI::InvalidURIError
    raise ArgumentError, 'URL is invalid'
  end

  def allowed_domain?(host)
    domains = Llm::RuntimePolicy.web_allowed_domains(preferences: runtime_preferences)
    return true if domains.blank?

    domain_match?(host, domains)
  end

  def blocked_domain?(host)
    domain_match?(host, Llm::RuntimePolicy.web_blocked_domains(preferences: runtime_preferences))
  end

  def domain_match?(host, domains)
    normalized_host = host.to_s.downcase
    domains.any? do |domain|
      normalized_host == domain || normalized_host.end_with?(".#{domain}")
    end
  end

  def private_host?(host)
    return true if %w[localhost localhost.localdomain].include?(host.to_s.downcase)

    ip = IPAddr.new(host)
    ip.private? || ip.loopback? || (ip.respond_to?(:link_local?) && ip.link_local?)
  rescue IPAddr::InvalidAddressError
    false
  end

  def truncate_text(value, max_chars)
    text = value.to_s
    return [text, false] if text.length <= max_chars

    [text.first(max_chars), true]
  end
end
