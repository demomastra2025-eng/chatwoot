# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

class Llm::OpenRouterEmbeddingClient
  DEFAULT_API_BASE = 'https://openrouter.ai/api/v1'
  REQUEST_TIMEOUT_SECONDS = 60

  Result = Struct.new(:vectors, :input_tokens, :model, keyword_init: true)

  class << self
    def embed(input, **options)
      api_key = options[:api_key]
      raise RubyLLM::ConfigurationError, 'OpenRouter API key is not configured for embeddings.' if api_key.blank?

      model = options[:model]
      uri = embeddings_uri(options[:api_base])
      request = embedding_request(uri, input, options)
      response = perform_request(uri, request)
      parse_response(response, model: model, dimensions: options[:dimensions])
    rescue JSON::ParserError => e
      raise RubyLLM::Error, "OpenRouter embedding returned invalid JSON: #{e.message}"
    rescue URI::InvalidURIError, OpenSSL::SSL::SSLError, EOFError, Timeout::Error, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET => e
      raise RubyLLM::Error, "OpenRouter embedding request failed: #{e.message}"
    end

    private

    def embedding_request(uri, input, options)
      Net::HTTP::Post.new(uri).tap do |request|
        request['Authorization'] = "Bearer #{options[:api_key]}"
        request['Content-Type'] = 'application/json'
        request['Accept'] = 'application/json'
        request.body = JSON.generate(
          {
            model: options[:model],
            input: input,
            dimensions: options[:dimensions],
            provider: options[:provider].presence
          }.compact
        )
      end
    end

    def perform_request(uri, request)
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https', read_timeout: REQUEST_TIMEOUT_SECONDS, open_timeout: 10) do |http|
        http.request(request)
      end
    end

    def parse_response(response, model:, dimensions:)
      success = response.code.to_i.between?(200, 299)
      body = parse_body(response.body, strict: success)
      raise request_error(body, response) unless success

      usage = response_usage(body)
      Result.new(
        vectors: response_vectors(body, model: model, dimensions: dimensions),
        input_tokens: usage['input_tokens'] || usage['prompt_tokens'],
        model: body['model'].presence || model
      )
    end

    def response_vectors(body, model:, dimensions:)
      data = body['data']
      raise RubyLLM::Error, 'OpenRouter embedding response did not include a vector.' unless data.is_a?(Array) && data.present?

      ordered_embedding_data(data).map do |item|
        vector = item.is_a?(Hash) ? item['embedding'] : nil
        validate_vector!(vector, model: model, dimensions: dimensions)
        vector
      end
    end

    def response_usage(body)
      body['usage'].is_a?(Hash) ? body['usage'] : {}
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
      "OpenRouter embedding failed: #{message}"
    end

    def ordered_embedding_data(data)
      return data unless data.all? { |item| item.is_a?(Hash) && item.key?('index') }

      data.sort_by { |item| item['index'].to_i }
    end

    def validate_vector!(vector, model:, dimensions:)
      raise RubyLLM::Error, 'OpenRouter embedding response did not include a vector.' unless vector.is_a?(Array)

      return if dimensions.blank? || vector.size == dimensions

      raise RubyLLM::Error,
            "OpenRouter embedding returned #{vector.size} dimensions for #{model}, expected #{dimensions}."
    end

    def embeddings_uri(api_base)
      URI("#{api_root(api_base)}/embeddings")
    end

    def api_root(api_base)
      base = api_base.presence || DEFAULT_API_BASE
      base.to_s
          .chomp('/')
          .delete_suffix('/audio/transcriptions')
          .delete_suffix('/embeddings/models')
          .delete_suffix('/embeddings')
          .delete_suffix('/models')
    end
  end
end
