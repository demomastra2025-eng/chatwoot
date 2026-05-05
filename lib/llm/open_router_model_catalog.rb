# frozen_string_literal: true

require 'bigdecimal'
require 'json'
require 'net/http'
require 'uri'

class Llm::OpenRouterModelCatalog
  PROVIDER = 'openrouter'
  DEFAULT_API_BASE = 'https://openrouter.ai/api/v1'
  CACHE_KEY = 'llm/openrouter/model_catalog'
  LAST_REFRESH_AT_CACHE_KEY = 'llm/openrouter/model_catalog/last_refresh_at'
  LAST_REFRESH_ERROR_CACHE_KEY = 'llm/openrouter/model_catalog/last_refresh_error'
  FALLBACK_SOURCE = 'config/llm_models.json'
  REQUEST_TIMEOUT_SECONDS = 20

  class MissingApiKeyError < StandardError; end
  class FetchError < StandardError; end

  class << self
    def refresh!(api_key: nil, api_base: nil)
      resolved_api_key = api_key.presence || Llm::Config.api_key(PROVIDER)
      raise MissingApiKeyError, 'OpenRouter API key is not configured.' if resolved_api_key.blank?

      payload = fetch_payload(models_uri(api_base.presence || Llm::Config.api_base(PROVIDER) || DEFAULT_API_BASE), resolved_api_key)
      model_configs = normalize_payload(payload)
      timestamp = Time.current.iso8601

      Rails.cache.write(CACHE_KEY, model_configs)
      Rails.cache.write(LAST_REFRESH_AT_CACHE_KEY, timestamp)
      Rails.cache.delete(LAST_REFRESH_ERROR_CACHE_KEY)

      metadata.merge(last_refreshed_at: timestamp, last_refresh_error: nil)
    rescue MissingApiKeyError
      raise
    rescue StandardError => e
      Rails.cache.write(LAST_REFRESH_ERROR_CACHE_KEY, refresh_error_message(e))
      raise
    end

    def sanitize_error_message(error)
      error.to_s
           .gsub(/(Bearer\s+)[^\s,;'"\\]+/i, '\\1[REDACTED]')
           .gsub(/sk-or-v1-[A-Za-z0-9_-]+/, '[REDACTED]')
           .gsub(/(api[_-]?key["'=:\s]+)[^\s,;'"\\]+/i, '\\1[REDACTED]')
    end

    def refresh_error_message(error)
      "#{error.class}: #{sanitize_error_message(error)}"
    end

    def model_configs
      cached_model_configs.presence || fallback_model_configs
    end

    def model_config(model_name)
      model_configs[model_name.to_s]
    end

    def model_ids
      model_configs.keys
    end

    def metadata
      configs = model_configs
      cached_configs = cached_model_configs
      {
        total_models: configs.count,
        chat_models: configs.count { |_, config| config['type'] == 'chat' },
        source: cached_configs.present? ? 'openrouter_api' : FALLBACK_SOURCE,
        using_fallback: cached_configs.blank?,
        fallback_models: fallback_model_configs.count,
        last_refreshed_at: Rails.cache.read(LAST_REFRESH_AT_CACHE_KEY),
        last_refresh_error: Rails.cache.read(LAST_REFRESH_ERROR_CACHE_KEY)
      }
    end

    def estimated_text_cost(model_name, input_tokens: 0, output_tokens: 0)
      pricing = model_config(model_name)&.fetch('pricing', nil)
      return if pricing.blank?

      prompt_price = decimal_price(pricing['prompt'])
      completion_price = decimal_price(pricing['completion'])
      return if prompt_price.zero? && completion_price.zero?

      ((prompt_price * input_tokens.to_i) + (completion_price * output_tokens.to_i)).to_f.round(8)
    end

    private

    def fetch_payload(uri, api_key)
      response = http_for(uri).request(request_for(uri, api_key))
      raise FetchError, "OpenRouter models API returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise FetchError, 'OpenRouter models API returned invalid JSON.'
    end

    def http_for(uri)
      Net::HTTP.new(uri.host, uri.port).tap do |http|
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = REQUEST_TIMEOUT_SECONDS
        http.read_timeout = REQUEST_TIMEOUT_SECONDS
      end
    end

    def request_for(uri, api_key)
      Net::HTTP::Get.new(uri).tap do |request|
        request['Authorization'] = "Bearer #{api_key}"
        request['Accept'] = 'application/json'
      end
    end

    def models_uri(api_base)
      base = api_base.to_s.chomp('/')
      URI(base.end_with?('/models') ? base : "#{base}/models")
    end

    def normalize_payload(payload)
      data = payload.is_a?(Hash) ? payload['data'] : nil
      raise FetchError, 'OpenRouter models API response is missing data array.' unless data.is_a?(Array)

      data.filter_map { |model_data| normalize_model(model_data, source: 'openrouter_api') }
          .sort_by { |id, config| [config['display_name'].to_s.downcase, id] }
          .to_h
    end

    def cached_model_configs
      normalize_cached_models(Rails.cache.read(CACHE_KEY))
    end

    def fallback_model_configs
      @fallback_model_configs ||= begin
        models = JSON.parse(Rails.root.join('config/llm_models.json').read)
        models.filter_map { |model_data| normalize_fallback_model(model_data) }
              .sort_by { |id, config| [config['display_name'].to_s.downcase, id] }
              .to_h
      rescue StandardError
        {}
      end
    end

    def normalize_cached_models(cached)
      return {} unless cached.is_a?(Hash)

      cached.each_with_object({}) do |(model_id, config), result|
        next unless config.is_a?(Hash)

        result[model_id.to_s] = config.deep_stringify_keys
      end
    end

    def normalize_model(model_data, source:)
      return unless model_data.is_a?(Hash)

      model_id = model_data['id'].to_s.strip
      return if model_id.blank?
      return unless text_output_model?(model_data)

      [
        model_id,
        {
          'provider' => PROVIDER,
          'display_name' => model_data['name'].presence || model_id,
          'credit_multiplier' => 1,
          'type' => 'chat',
          'capabilities' => capabilities_for(model_data),
          'context_length' => integer_value(model_data['context_length']),
          'max_output_tokens' => integer_value(model_data.dig('top_provider', 'max_completion_tokens')),
          'pricing' => pricing_for(model_data),
          'description' => model_data['description'].to_s.presence,
          'source' => source
        }.compact
      ]
    end

    def normalize_fallback_model(model_data)
      return unless model_data.is_a?(Hash)
      return unless model_data['provider'].to_s == PROVIDER

      model_id = model_data['id'].to_s.strip
      return if model_id.blank?
      return unless fallback_text_output_model?(model_data)

      [
        model_id,
        {
          'provider' => PROVIDER,
          'display_name' => model_data['name'].presence || model_id,
          'credit_multiplier' => 1,
          'type' => 'chat',
          'capabilities' => fallback_capabilities_for(model_data),
          'context_length' => integer_value(model_data['context_window'] || model_data.dig('metadata', 'limit', 'context')),
          'max_output_tokens' => integer_value(model_data['max_output_tokens'] || model_data.dig('metadata', 'limit', 'output')),
          'pricing' => fallback_pricing_for(model_data),
          'description' => model_data['description'].to_s.presence,
          'source' => FALLBACK_SOURCE
        }.compact
      ]
    end

    def text_output_model?(model_data)
      architecture = model_data['architecture'].is_a?(Hash) ? model_data['architecture'] : {}
      output_modalities = Array(architecture['output_modalities']).map(&:to_s)
      modality = architecture['modality'].to_s

      return output_modalities.include?('text') if output_modalities.present?
      return modality.split('->').last.to_s.include?('text') if modality.present?

      true
    end

    def fallback_text_output_model?(model_data)
      output_modalities = Array(model_data.dig('modalities', 'output')).map(&:to_s)
      return output_modalities.include?('text') if output_modalities.present?

      true
    end

    def capabilities_for(model_data)
      architecture = model_data['architecture'].is_a?(Hash) ? model_data['architecture'] : {}
      input_modalities = Array(architecture['input_modalities']).map(&:to_s)
      supported_parameters = Array(model_data['supported_parameters']).map(&:to_s)
      capabilities = ['streaming']

      capabilities << 'tool_calling' if supported_parameters.intersect?(%w[tools tool_choice])
      capabilities << 'structured_output' if supported_parameters.intersect?(%w[response_format structured_outputs])
      capabilities << 'reasoning' if supported_parameters.intersect?(%w[reasoning reasoning_effort include_reasoning])
      capabilities << 'multimodal_input' if (input_modalities - ['text']).any?

      capabilities.uniq
    end

    def fallback_capabilities_for(model_data)
      input_modalities = Array(model_data.dig('modalities', 'input')).map(&:to_s)
      configured_capabilities = Array(model_data['capabilities']).map(&:to_s)
      capabilities = ['streaming']

      capabilities << 'tool_calling' if configured_capabilities.include?('function_calling') || configured_capabilities.include?('tool_calling')
      capabilities << 'structured_output' if configured_capabilities.intersect?(%w[structured_output response_format json_schema structured_outputs])
      capabilities << 'reasoning' if configured_capabilities.include?('reasoning')
      capabilities << 'multimodal_input' if configured_capabilities.include?('vision') || (input_modalities - ['text']).any?

      capabilities.uniq
    end

    def pricing_for(model_data)
      pricing = model_data['pricing'].is_a?(Hash) ? model_data['pricing'] : {}
      pricing.slice('prompt', 'completion', 'image', 'request', 'input_cache_read', 'internal_reasoning')
             .compact
             .transform_values(&:to_s)
    end

    def fallback_pricing_for(model_data)
      standard_text_pricing = model_data.dig('pricing', 'text_tokens', 'standard') || {}
      input_per_million = decimal_price(standard_text_pricing['input_per_million'] || model_data.dig('metadata', 'cost', 'input'))
      output_per_million = decimal_price(standard_text_pricing['output_per_million'] || model_data.dig('metadata', 'cost', 'output'))
      cache_read_per_million = decimal_price(standard_text_pricing['cached_input_per_million'] || model_data.dig('metadata', 'cost', 'cache_read'))

      {
        'prompt' => per_token_price(input_per_million),
        'completion' => per_token_price(output_per_million),
        'input_cache_read' => per_token_price(cache_read_per_million)
      }.compact
    end

    def integer_value(value)
      return if value.blank?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def decimal_price(value)
      return BigDecimal(0) if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      BigDecimal(0)
    end

    def per_token_price(per_million_price)
      return if per_million_price.zero?

      (per_million_price / 1_000_000).to_s('F')
    end
  end
end
