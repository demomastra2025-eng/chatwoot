# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

class Llm::OpenRouterRerankClient
  DEFAULT_API_BASE = 'https://openrouter.ai/api/v1'
  REQUEST_TIMEOUT_SECONDS = 60

  ResultItem = Struct.new(:index, :relevance_score, :document, keyword_init: true)
  Result = Struct.new(:results, :model, :usage, :raw, keyword_init: true)

  class << self
    def rerank(query:, documents:, **options)
      api_key = options[:api_key]
      raise RubyLLM::ConfigurationError, 'OpenRouter API key is not configured for rerank.' if api_key.blank?
      raise ArgumentError, 'OpenRouter rerank model is required.' if options[:model].blank?
      raise ArgumentError, 'OpenRouter rerank query is required.' if query.blank?

      documents = Array(documents)
      raise ArgumentError, 'OpenRouter rerank documents are required.' if documents.blank?

      uri = rerank_uri(options[:api_base])
      request = rerank_request(uri, query, documents, options)
      response = perform_request(uri, request)
      parse_response(response, model: options[:model])
    rescue JSON::ParserError => e
      raise RubyLLM::Error, "OpenRouter rerank returned invalid JSON: #{e.message}"
    rescue URI::InvalidURIError, OpenSSL::SSL::SSLError, EOFError, Timeout::Error, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET => e
      raise RubyLLM::Error, "OpenRouter rerank request failed: #{e.message}"
    end

    private

    def rerank_request(uri, query, documents, options)
      Net::HTTP::Post.new(uri).tap do |request|
        request['Authorization'] = "Bearer #{options[:api_key]}"
        request['Content-Type'] = 'application/json'
        request['Accept'] = 'application/json'
        Llm::OpenRouterHeaders.apply!(request, headers: options[:headers])
        request.body = JSON.generate(
          {
            model: options[:model],
            query: query,
            documents: documents,
            top_n: options[:top_n],
            return_documents: options.fetch(:return_documents, true),
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

    def parse_response(response, model:)
      success = response.code.to_i.between?(200, 299)
      body = parse_body(response.body, strict: success)
      raise request_error(body, response) unless success

      Result.new(
        results: response_results(body),
        model: body['model'].presence || model,
        usage: body['usage'].is_a?(Hash) ? body['usage'] : {},
        raw: body
      )
    end

    def response_results(body)
      data = body['results'].presence || body['data']
      raise RubyLLM::Error, 'OpenRouter rerank response did not include results.' unless data.is_a?(Array)

      data.map { |item| result_item(item) }
    end

    def result_item(item)
      raise RubyLLM::Error, 'OpenRouter rerank response included an invalid result.' unless item.is_a?(Hash)

      index = item['index']
      raise RubyLLM::Error, 'OpenRouter rerank response result did not include an index.' if index.blank?

      ResultItem.new(
        index: index.to_i,
        relevance_score: numeric_value(item['relevance_score'] || item['score'] || item['relevanceScore']),
        document: item['document']
      )
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
      "OpenRouter rerank failed: #{message}"
    end

    def rerank_uri(api_base)
      URI("#{api_root(api_base)}/rerank")
    end

    def api_root(api_base)
      base = api_base.presence || DEFAULT_API_BASE
      base.to_s
          .chomp('/')
          .delete_suffix('/audio/transcriptions')
          .delete_suffix('/embeddings/models')
          .delete_suffix('/embeddings')
          .delete_suffix('/rerank')
          .delete_suffix('/models')
    end

    def numeric_value(value)
      return if value.blank?

      Float(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
