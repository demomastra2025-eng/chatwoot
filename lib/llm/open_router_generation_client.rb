# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

class Llm::OpenRouterGenerationClient
  DEFAULT_API_BASE = 'https://openrouter.ai/api/v1'
  REQUEST_TIMEOUT_SECONDS = 30

  Result = Struct.new(
    :generation_id,
    :provider_name,
    :model,
    :cost,
    :latency_ms,
    :finish_reason,
    :error_code,
    :error_reason,
    :prompt_tokens,
    :completion_tokens,
    :reasoning_tokens,
    :cached_tokens,
    :raw,
    keyword_init: true
  )

  class << self
    def fetch(generation_id, **options)
      raise RubyLLM::ConfigurationError, 'OpenRouter generation id is required.' if generation_id.blank?

      api_key = options[:api_key]
      raise RubyLLM::ConfigurationError, 'OpenRouter API key is not configured for generation metadata.' if api_key.blank?

      uri = generation_uri(generation_id, options[:api_base])
      request = generation_request(uri, api_key)
      response = perform_request(uri, request)
      parse_response(response, requested_generation_id: generation_id)
    rescue JSON::ParserError => e
      raise RubyLLM::Error, "OpenRouter generation metadata returned invalid JSON: #{e.message}"
    rescue URI::InvalidURIError, OpenSSL::SSL::SSLError, EOFError, Timeout::Error, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET => e
      raise RubyLLM::Error, "OpenRouter generation metadata request failed: #{e.message}"
    end

    private

    def generation_request(uri, api_key)
      Net::HTTP::Get.new(uri).tap do |request|
        request['Authorization'] = "Bearer #{api_key}"
        request['Accept'] = 'application/json'
        Llm::OpenRouterHeaders.apply!(request)
      end
    end

    def perform_request(uri, request)
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https', read_timeout: REQUEST_TIMEOUT_SECONDS, open_timeout: 10) do |http|
        http.request(request)
      end
    end

    def parse_response(response, requested_generation_id:)
      success = response.code.to_i.between?(200, 299)
      body = parse_body(response.body, strict: success)
      raise request_error(body, response) unless success

      result_from_data(generation_data(body), requested_generation_id: requested_generation_id, raw: body)
    end

    def result_from_data(data, requested_generation_id:, raw:)
      data = data.to_h.with_indifferent_access
      Result.new(
        generation_id: data['id'].presence || requested_generation_id,
        provider_name: data['provider_name'].presence || data['provider'],
        model: data['model'],
        cost: data['total_cost'].presence || data['cost'],
        latency_ms: latency_ms(data),
        finish_reason: finish_reason(data),
        error_code: error_code(data),
        error_reason: error_reason(data),
        prompt_tokens: token_count(data, 'tokens_prompt', 'prompt_tokens', 'input_tokens'),
        completion_tokens: token_count(data, 'tokens_completion', 'completion_tokens', 'output_tokens'),
        reasoning_tokens: token_count(data, 'native_tokens_reasoning', 'reasoning_tokens'),
        cached_tokens: token_count(data, 'cached_tokens', 'cache_read_tokens'),
        raw: raw
      )
    end

    def latency_ms(data)
      integer_value(data['latency_ms'] || data['latency'] || data['generation_time'])
    end

    def finish_reason(data)
      data['finish_reason'].presence || data['native_finish_reason'].presence || data['finish'].presence
    end

    def error_code(data)
      data['error_code'].presence || data['code'].presence || error_value(data, 'code')
    end

    def error_reason(data)
      data['error_reason'].presence || data['error_message'].presence || error_value(data, 'message') || error_value(data, 'error')
    end

    def error_value(data, key)
      error = data['error'].presence || data['provider_error'].presence
      return if error.blank?
      return error[key] if error.is_a?(Hash)

      error.to_s if key == 'message' || key == 'error'
    end

    def token_count(data, *keys)
      keys.each do |key|
        value = data[key] || usage_value(data, key)
        return integer_value(value) if value.present?
      end
      nil
    end

    def generation_data(body)
      data = body.is_a?(Hash) ? body['data'] : nil
      data.is_a?(Hash) ? data : body.to_h
    end

    def usage_value(data, key)
      usage = data['usage']
      return unless usage.is_a?(Hash)

      usage[key]
    end

    def parse_body(response_body, strict:)
      JSON.parse(response_body)
    rescue JSON::ParserError
      raise if strict

      {}
    end

    def request_error(body, response)
      message = openrouter_error_message(body, response)
      return RubyLLM::UnauthorizedError.new(message) if response.code.to_i == 401

      RubyLLM::Error.new(message)
    end

    def openrouter_error_message(body, response)
      error = body.is_a?(Hash) ? body['error'] : nil
      message = error.is_a?(Hash) ? error['message'] : error
      message = "HTTP #{response.code} #{response.message}".strip if message.blank?
      "OpenRouter generation metadata failed: #{message}"
    end

    def generation_uri(generation_id, api_base)
      uri = URI("#{api_root(api_base)}/generation")
      uri.query = URI.encode_www_form(id: generation_id)
      uri
    end

    def api_root(api_base)
      base = api_base.presence || DEFAULT_API_BASE
      base.to_s
          .chomp('/')
          .delete_suffix('/generation')
          .delete_suffix('/chat/completions')
          .delete_suffix('/audio/transcriptions')
          .delete_suffix('/embeddings/models')
          .delete_suffix('/embeddings')
          .delete_suffix('/models')
    end

    def integer_value(value)
      return if value.blank?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
