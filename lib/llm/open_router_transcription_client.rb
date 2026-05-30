# frozen_string_literal: true

require 'base64'
require 'json'
require 'net/http'
require 'uri'

class Llm::OpenRouterTranscriptionClient
  DEFAULT_API_BASE = 'https://openrouter.ai/api/v1'
  REQUEST_TIMEOUT_SECONDS = 120

  class << self
    def transcribe(file_path, **options)
      model = options[:model]
      api_key = options[:api_key]
      raise RubyLLM::ConfigurationError, 'OpenRouter API key is not configured for transcription.' if api_key.blank?

      uri = transcription_uri(options[:api_base])
      request = transcription_request(uri, file_path, options)
      response = perform_request(uri, request)
      parse_response(response, model: model)
    rescue JSON::ParserError => e
      raise RubyLLM::Error, "OpenRouter transcription returned invalid JSON: #{e.message}"
    rescue URI::InvalidURIError, OpenSSL::SSL::SSLError, EOFError, Timeout::Error, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET => e
      raise RubyLLM::Error, "OpenRouter transcription request failed: #{e.message}"
    end

    private

    def transcription_request(uri, file_path, options)
      Net::HTTP::Post.new(uri).tap do |request|
        request['Authorization'] = "Bearer #{options[:api_key]}"
        request['Content-Type'] = 'application/json'
        request['Accept'] = 'application/json'
        request.body = JSON.generate(
          {
            model: options[:model],
            input_audio: {
              data: Base64.strict_encode64(File.binread(file_path)),
              format: Llm::OpenRouterAudioInput.format_for(file_path)
            },
            language: options[:language].presence,
            temperature: options[:temperature],
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

      usage = body['usage'].is_a?(Hash) ? body['usage'] : {}
      RubyLLM::Transcription.new(
        text: body['text'].to_s,
        model: model,
        language: body['language'],
        duration: usage['seconds'] || body['duration'],
        input_tokens: usage['input_tokens'] || usage['prompt_tokens'],
        output_tokens: usage['output_tokens'] || usage['completion_tokens']
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
      message.presence || "OpenRouter transcription failed: HTTP #{response.code} #{response.message}".strip
    end

    def transcription_uri(api_base)
      URI("#{api_root(api_base)}/audio/transcriptions")
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
