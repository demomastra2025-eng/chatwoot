# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require 'timeout'

class Llm::OpenRouterDecisionClient
  SUPPORTED_MODELS = %w[
    microsoft/microsoft-decision-1 microsoft/microsoft-decision-1-20261009 openai/gpt-6-luna-decisions
  ].freeze
  DEFAULT_API_BASE = 'https://openrouter.ai/api/v1'
  REQUEST_TIMEOUT_SECONDS = 110
  MAX_RESPONSE_BYTES = 1_048_576
  MAX_REQUEST_BYTES = 131_072
  Result = Struct.new(:choice, :confidence, :model, :provider, :request_id, :usage, keyword_init: true)

  class Error < StandardError; end

  class << self
    def supported_model?(model)
      SUPPORTED_MODELS.include?(model)
    end

    def choose(state:, criteria:, instructions:, **options)
      validate_request!(state, criteria, instructions, options)
      uri = decision_uri(options[:api_base])
      request = build_request(uri, state, criteria, instructions, options)
      code, body = perform_request(uri, request)
      raise Error, "OpenRouter decision request failed (HTTP #{code})." unless code.between?(200, 299)

      parse_response(body, criteria)
    rescue JSON::ParserError
      raise Error, 'OpenRouter decision returned invalid JSON.'
    rescue Timeout::Error, OpenSSL::SSL::SSLError, EOFError, SocketError, SystemCallError, Net::HTTPBadResponse
      # Do not propagate provider bodies, request data, URLs or credentials into logs.
      raise Error, 'OpenRouter decision transport unavailable.'
    end

    private

    def validate_request!(state, criteria, instructions, options)
      raise ArgumentError, 'Unsupported decision model.' unless supported_model?(options[:model])
      raise ArgumentError, 'OpenRouter decision key is required.' unless options[:api_key].is_a?(String) && options[:api_key].present?
      raise ArgumentError, 'Invalid decision state.' unless state.is_a?(Hash)
      raise ArgumentError, 'Invalid decision instructions.' unless instructions.is_a?(String) && instructions.length.between?(1, 8000)
      raise ArgumentError, 'Invalid decision choices.' unless criteria.is_a?(Hash) && criteria.size.between?(2, 64)

      valid = criteria.all? do |key, value|
        key.is_a?(String) && key.match?(/\A[a-zA-Z0-9_-]{1,100}\z/) && value.is_a?(String) && value.length.between?(1, 2000)
      end
      raise ArgumentError, 'Invalid decision choices.' unless valid
    end

    def build_request(uri, state, criteria, instructions, options)
      body = JSON.generate(model: options[:model], state: state,
                           questions: { reason: { type: 'choice', instructions: instructions, criteria: criteria } },
                           provider: options[:provider].presence)
      raise ArgumentError, 'Decision request too large.' if body.bytesize > MAX_REQUEST_BYTES

      Net::HTTP::Post.new(uri).tap do |request|
        request['Authorization'] = "Bearer #{options[:api_key]}"
        request['Content-Type'] = 'application/json'
        request['Accept'] = 'application/json'
        Llm::OpenRouterHeaders.apply!(request, headers: options[:headers])
        request.body = body
      end
    end

    def perform_request(uri, request)
      # Two sequential calls (short fragment, optional expansion) stay below the 300s job lease.
      Timeout.timeout(REQUEST_TIMEOUT_SECONDS) do
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 90, write_timeout: 10) do |http|
          http.max_retries = 0
          http.request(request) do |response|
            body = +''
            response.read_body do |chunk|
              body << chunk
              raise Error, 'OpenRouter decision response too large.' if body.bytesize > MAX_RESPONSE_BYTES
            end
            return [response.code.to_i, body]
          end
        end
      end
    end

    def parse_response(body, criteria)
      data = JSON.parse(body)
      answer = data.is_a?(Hash) && data['answers'].is_a?(Hash) ? data['answers']['reason'] : nil
      unless answer.is_a?(Hash) && criteria.key?(answer['choice']) && data['model'].is_a?(String) && data['model'].length.between?(1, 200)
        raise Error, 'OpenRouter decision returned an invalid selection.'
      end

      confidence = answer['confidence']
      if !confidence.nil? && (!confidence.is_a?(Numeric) || !confidence.finite? || !confidence.between?(0, 1))
        raise Error, 'OpenRouter decision returned invalid confidence.'
      end

      Result.new(choice: answer['choice'], confidence: confidence, model: data['model'],
                 provider: safe_identifier(data['provider']), request_id: safe_identifier(data['id']), usage: safe_usage(data['usage']))
    end

    def safe_usage(value)
      return {} unless value.is_a?(Hash)

      value.slice('input_tokens', 'output_tokens', 'total_tokens', 'cost').select do |_key, number|
        number.is_a?(Numeric) && number.finite? && number >= 0
      end
    end

    def safe_identifier(value)
      value if value.is_a?(String) && value.length.between?(1, 256) && !value.match?(/[\r\n]/)
    end

    def decision_uri(api_base)
      uri = URI(api_base.presence || DEFAULT_API_BASE)
      unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
        raise ArgumentError, 'Invalid OpenRouter decision endpoint.'
      end

      base_path = uri.path.chomp('/').delete_suffix('/chat/completions').delete_suffix('/models')
      uri.path = case base_path
                 when %r{/alpha/decisions\z} then base_path
                 when %r{/v1\z} then "#{base_path.delete_suffix('/v1')}/alpha/decisions"
                 when %r{/api\z} then "#{base_path}/alpha/decisions"
                 else raise ArgumentError, 'Unsupported OpenRouter decision endpoint.'
                 end
      uri
    rescue URI::InvalidURIError
      raise ArgumentError, 'Invalid OpenRouter decision endpoint.'
    end
  end
end
