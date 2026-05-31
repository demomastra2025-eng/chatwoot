# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

class Llm::OpenRouterKeyClient
  DEFAULT_API_BASE = 'https://openrouter.ai/api/v1'
  REQUEST_TIMEOUT_SECONDS = 15

  KeyResult = Struct.new(
    :label,
    :usage,
    :usage_daily,
    :usage_weekly,
    :usage_monthly,
    :limit,
    :limit_remaining,
    :limit_reset,
    :include_byok_in_limit,
    :byok_usage,
    :byok_usage_daily,
    :byok_usage_weekly,
    :byok_usage_monthly,
    :free_tier,
    :management_key,
    :provisioning_key,
    :expires_at,
    :raw,
    keyword_init: true
  ) do
    def key_type
      return 'management' if management_key
      return 'provisioning' if provisioning_key

      'api'
    end

    def management_capable?
      management_key
    end

    def to_h
      {
        label: label,
        key_type: key_type,
        usage: usage,
        usage_daily: usage_daily,
        usage_weekly: usage_weekly,
        usage_monthly: usage_monthly,
        limit: limit,
        limit_remaining: limit_remaining,
        limit_reset: limit_reset,
        include_byok_in_limit: include_byok_in_limit,
        byok_usage: byok_usage,
        byok_usage_daily: byok_usage_daily,
        byok_usage_weekly: byok_usage_weekly,
        byok_usage_monthly: byok_usage_monthly,
        free_tier: free_tier,
        management_key: management_key,
        provisioning_key: provisioning_key,
        expires_at: expires_at
      }.compact
    end
  end

  CreditsResult = Struct.new(:total_credits, :total_usage, :remaining_credits, :raw, keyword_init: true) do
    def to_h
      {
        total_credits: total_credits,
        total_usage: total_usage,
        remaining_credits: remaining_credits
      }.compact
    end
  end

  class << self
    def current_key(api_key:, api_base: nil)
      raise RubyLLM::ConfigurationError, 'OpenRouter API key is not configured for key health.' if api_key.blank?

      response = perform_get('/key', api_key: api_key, api_base: api_base)
      result_from_key_data(response)
    rescue JSON::ParserError => e
      raise RubyLLM::Error, "OpenRouter key health returned invalid JSON: #{e.message}"
    rescue URI::InvalidURIError, OpenSSL::SSL::SSLError, EOFError, Timeout::Error, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET => e
      raise RubyLLM::Error, "OpenRouter key health request failed: #{e.message}"
    end

    def credits(api_key:, api_base: nil)
      raise RubyLLM::ConfigurationError, 'OpenRouter API key is not configured for credits.' if api_key.blank?

      response = perform_get('/credits', api_key: api_key, api_base: api_base)
      result_from_credits_data(response)
    rescue JSON::ParserError => e
      raise RubyLLM::Error, "OpenRouter credits returned invalid JSON: #{e.message}"
    rescue URI::InvalidURIError, OpenSSL::SSL::SSLError, EOFError, Timeout::Error, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET => e
      raise RubyLLM::Error, "OpenRouter credits request failed: #{e.message}"
    end

    private

    def perform_get(path, api_key:, api_base:)
      uri = URI("#{api_root(api_base)}#{path}")
      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Bearer #{api_key}"
      request['Accept'] = 'application/json'
      response = Net::HTTP.start(
        uri.hostname,
        uri.port,
        use_ssl: uri.scheme == 'https',
        read_timeout: REQUEST_TIMEOUT_SECONDS,
        open_timeout: 10
      ) { |http| http.request(request) }
      parse_response(response, path: path)
    end

    def parse_response(response, path:)
      success = response.code.to_i.between?(200, 299)
      body = parse_body(response.body, strict: success)
      raise request_error(body, response, path: path) unless success

      body
    end

    def parse_body(response_body, strict:)
      JSON.parse(response_body)
    rescue JSON::ParserError
      raise if strict

      {}
    end

    def request_error(body, response, path:)
      message = openrouter_error_message(body, response, path: path)
      return RubyLLM::UnauthorizedError.new(message) if response.code.to_i == 401

      RubyLLM::Error.new(message)
    end

    def openrouter_error_message(body, response, path:)
      error = body.is_a?(Hash) ? body['error'] : nil
      message = error.is_a?(Hash) ? error['message'] : error
      message = "HTTP #{response.code} #{response.message}".strip if message.blank?
      message = Llm::ObservabilityPayload.sanitize_error_message(message)
      "OpenRouter #{path.delete_prefix('/')} request failed: #{message}"
    end

    def result_from_key_data(body)
      data = response_data(body)
      KeyResult.new(
        label: data['label'],
        usage: decimal_value(data['usage']),
        usage_daily: decimal_value(data['usage_daily']),
        usage_weekly: decimal_value(data['usage_weekly']),
        usage_monthly: decimal_value(data['usage_monthly']),
        limit: decimal_value(data['limit']),
        limit_remaining: decimal_value(data['limit_remaining']),
        limit_reset: data['limit_reset'],
        include_byok_in_limit: data['include_byok_in_limit'],
        byok_usage: decimal_value(data['byok_usage']),
        byok_usage_daily: decimal_value(data['byok_usage_daily']),
        byok_usage_weekly: decimal_value(data['byok_usage_weekly']),
        byok_usage_monthly: decimal_value(data['byok_usage_monthly']),
        free_tier: data['is_free_tier'],
        management_key: data['is_management_key'],
        provisioning_key: data['is_provisioning_key'],
        expires_at: data['expires_at'],
        raw: body
      )
    end

    def result_from_credits_data(body)
      data = response_data(body)
      total_credits = decimal_value(data['total_credits'])
      total_usage = decimal_value(data['total_usage'])
      CreditsResult.new(
        total_credits: total_credits,
        total_usage: total_usage,
        remaining_credits: compact_difference(total_credits, total_usage),
        raw: body
      )
    end

    def response_data(body)
      body.to_h.fetch('data', {}).to_h.with_indifferent_access
    end

    def decimal_value(value)
      return if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    def compact_difference(left, right)
      return if left.nil? || right.nil?

      left - right
    end

    def api_root(api_base)
      base = api_base.presence || DEFAULT_API_BASE
      base.to_s
          .chomp('/')
          .delete_suffix('/key')
          .delete_suffix('/keys')
          .delete_suffix('/credits')
          .delete_suffix('/chat/completions')
          .delete_suffix('/models')
    end
  end
end
