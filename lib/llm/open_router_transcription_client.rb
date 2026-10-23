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
        Llm::OpenRouterHeaders.apply!(request, headers: options[:headers])
        request.body = JSON.generate(
          {
            model: options[:model],
            input_audio: {
              data: Base64.strict_encode64(File.binread(file_path)),
              format: Llm::OpenRouterAudioInput.format_for(file_path)
            },
            language: options[:language].presence,
            temperature: options[:temperature],
            provider: provider_payload(options)
          }.compact
        )
      end
    end

    # OpenRouter's JSON transcription body has no top-level `prompt`: a field it does not know is dropped without an error.
    # The prompt is a provider option, forwarded under the slug of the provider that serves the model, in that provider's
    # own field name: provider.options.openai.prompt. `language` and `temperature` are normalized and stay top-level.
    # https://openrouter.ai/docs/guides/overview/multimodal/stt.md (Provider-Specific Options)
    def provider_payload(options)
      provider = options[:provider].to_h.deep_symbolize_keys
      prompt = options[:prompt].presence
      slug = provider_slug(options[:model])
      provider[:options] = provider[:options].to_h.deep_merge(slug.to_sym => { prompt: prompt }) if prompt && slug
      provider.presence
    end

    # The vendor part of the model id (openai/gpt-4o-transcribe -> openai). It is the slug of the endpoint for the OpenAI
    # transcription models. A model that is served by other providers needs the slug of the provider that serves it.
    def provider_slug(model)
      vendor, name = model.to_s.split('/', 2)
      vendor.presence if name.present?
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
