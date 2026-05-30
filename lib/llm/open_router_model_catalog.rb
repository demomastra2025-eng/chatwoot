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
  INSTALLATION_CONFIG_KEY = 'CAPTAIN_OPENROUTER_MODEL_CATALOG'
  FALLBACK_SOURCE = 'config/llm_models.json'
  REQUEST_TIMEOUT_SECONDS = 20
  VECTOR_DIMENSIONS = Captain::KnowledgeSettings::VECTOR_DIMENSIONS

  class MissingApiKeyError < StandardError; end
  class FetchError < StandardError; end

  class << self
    def refresh!(api_key: nil, api_base: nil)
      resolved_api_key = api_key.presence || Llm::Config.api_key(PROVIDER)
      raise MissingApiKeyError, 'OpenRouter API key is not configured.' if resolved_api_key.blank?

      resolved_api_base = api_base.presence || Llm::Config.api_base(PROVIDER) || DEFAULT_API_BASE
      model_configs = normalize_models_payload(fetch_payload(models_uri(resolved_api_base), resolved_api_key))
                      .merge(normalize_embedding_payload(fetch_payload(embedding_models_uri(resolved_api_base), resolved_api_key)))
                      .sort_by { |id, config| [config['display_name'].to_s.downcase, id] }
                      .to_h
      timestamp = Time.current.iso8601(6)
      @last_model_configs = model_configs
      @last_refreshed_at = timestamp
      @last_refresh_error = nil
      @cached_model_configs = model_configs
      @cached_model_configs_refresh_marker = timestamp
      @cached_model_configs_loaded = true

      persist_model_catalog(model_configs, timestamp)
      Rails.cache.write(CACHE_KEY, model_configs)
      Rails.cache.write(LAST_REFRESH_AT_CACHE_KEY, timestamp)
      Rails.cache.delete(LAST_REFRESH_ERROR_CACHE_KEY)

      metadata.merge(last_refreshed_at: timestamp, last_refresh_error: nil)
    rescue MissingApiKeyError
      raise
    rescue StandardError => e
      @last_refresh_error = refresh_error_message(e)
      persist_refresh_error(@last_refresh_error)
      Rails.cache.write(LAST_REFRESH_ERROR_CACHE_KEY, @last_refresh_error)
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
      current_model_configs_snapshot || refreshed_model_configs.presence || fallback_model_configs
    end

    def with_model_configs_snapshot
      previous_snapshot = Thread.current[model_configs_snapshot_key]
      Thread.current[model_configs_snapshot_key] = model_configs
      yield
    ensure
      Thread.current[model_configs_snapshot_key] = previous_snapshot
    end

    def model_config(model_name)
      model_configs[model_name.to_s]
    end

    def model_ids
      model_configs.keys
    end

    def metadata
      api_configs = refreshed_model_configs
      configs = api_configs.presence || fallback_model_configs
      persistent_payload = persisted_model_catalog_payload
      {
        total_models: configs.count,
        chat_models: configs.count { |_, config| config['type'] == 'chat' },
        transcription_models: configs.count { |_, config| config['type'] == 'transcription' },
        embedding_models: configs.count { |_, config| config['type'] == 'embedding' },
        rerank_models: configs.count { |_, config| config['type'] == 'rerank' },
        source: api_configs.present? ? 'openrouter_api' : FALLBACK_SOURCE,
        using_fallback: api_configs.blank?,
        fallback_models: fallback_model_configs.count,
        last_refreshed_at: Rails.cache.read(LAST_REFRESH_AT_CACHE_KEY) || @last_refreshed_at || persistent_payload['last_refreshed_at'],
        last_refresh_error: Rails.cache.read(LAST_REFRESH_ERROR_CACHE_KEY) || @last_refresh_error || persistent_payload['last_refresh_error']
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

    def current_model_configs_snapshot
      Thread.current[model_configs_snapshot_key]
    end

    def model_configs_snapshot_key
      :llm_openrouter_model_catalog_model_configs_snapshot
    end

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
      URI("#{api_root(api_base)}/models?output_modalities=all")
    end

    def embedding_models_uri(api_base)
      URI("#{api_root(api_base)}/embeddings/models")
    end

    def api_root(api_base)
      api_base.to_s.chomp('/').delete_suffix('/embeddings/models').delete_suffix('/models')
    end

    def normalize_models_payload(payload)
      data = payload.is_a?(Hash) ? payload['data'] : nil
      raise FetchError, 'OpenRouter models API response is missing data array.' unless data.is_a?(Array)

      normalized_models = data.flat_map do |model_data|
        [
          normalize_chat_model(model_data, source: 'openrouter_api'),
          normalize_transcription_model(model_data, source: 'openrouter_api'),
          normalize_rerank_model(model_data, source: 'openrouter_api')
        ].compact
      end

      normalized_models.sort_by { |id, config| [config['display_name'].to_s.downcase, id] }.to_h
    end

    def normalize_embedding_payload(payload)
      data = payload.is_a?(Hash) ? payload['data'] : nil
      raise FetchError, 'OpenRouter embeddings models API response is missing data array.' unless data.is_a?(Array)

      data.filter_map { |model_data| normalize_embedding_model(model_data, source: 'openrouter_api') }
          .sort_by { |id, config| [config['display_name'].to_s.downcase, id] }
          .to_h
    end

    def cached_model_configs
      refresh_marker = Rails.cache.read(LAST_REFRESH_AT_CACHE_KEY)

      if refresh_marker.present? && defined?(@cached_model_configs_loaded) && @cached_model_configs_loaded &&
         @cached_model_configs_refresh_marker == refresh_marker
        return @cached_model_configs
      end

      cached_configs = normalize_cached_models(Rails.cache.read(CACHE_KEY))
      if refresh_marker.present?
        @cached_model_configs = cached_configs
        @cached_model_configs_refresh_marker = refresh_marker
        @cached_model_configs_loaded = true
      end

      cached_configs
    end

    def refreshed_model_configs
      cached_model_configs.presence || persisted_model_configs.presence || in_memory_model_configs
    end

    def in_memory_model_configs
      normalize_cached_models(@last_model_configs)
    end

    def persisted_model_configs
      normalize_cached_models(persisted_model_catalog_payload['models'])
    end

    def persisted_model_catalog_payload
      payload = InstallationConfig.find_by(name: INSTALLATION_CONFIG_KEY)&.value
      payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      {}
    end

    def persist_model_catalog(model_configs, timestamp)
      persist_model_catalog_payload(
        'models' => model_configs,
        'last_refreshed_at' => timestamp,
        'last_refresh_error' => nil
      )
    end

    def persist_refresh_error(error_message)
      payload = persisted_model_catalog_payload
      payload['last_refresh_error'] = error_message
      persist_model_catalog_payload(payload)
    end

    def persist_model_catalog_payload(payload)
      config = InstallationConfig.find_or_initialize_by(name: INSTALLATION_CONFIG_KEY)
      config.value = payload
      config.locked = false
      config.save!
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      nil
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

    def normalize_chat_model(model_data, source:)
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
          'input_modalities' => input_modalities_for(model_data),
          'output_modalities' => output_modalities_for(model_data),
          'context_length' => integer_value(model_data['context_length']),
          'max_output_tokens' => integer_value(model_data.dig('top_provider', 'max_completion_tokens')),
          'pricing' => pricing_for(model_data),
          'latency_ms' => numeric_value(model_data.dig('top_provider', 'latency_ms') || model_data.dig('top_provider', 'latency') ||
                                        model_data['latency_ms'] || model_data['latency']),
          'throughput_tokens_per_second' => numeric_value(model_data.dig('top_provider', 'throughput_tokens_per_second') ||
                                                          model_data.dig('top_provider', 'throughput') ||
                                                          model_data['throughput_tokens_per_second'] || model_data['tokens_per_second'] ||
                                                          model_data['throughput']),
          'description' => model_data['description'].to_s.presence,
          'source' => source
        }.compact
      ]
    end

    def normalize_embedding_model(model_data, source:)
      return unless model_data.is_a?(Hash)

      model_id = model_data['id'].to_s.strip
      return if model_id.blank?
      return unless embedding_output_model?(model_data)

      [
        model_id,
        {
          'provider' => PROVIDER,
          'display_name' => model_data['name'].presence || model_id,
          'credit_multiplier' => 1,
          'type' => 'embedding',
          'capabilities' => embedding_capabilities_for(model_data),
          'input_modalities' => input_modalities_for(model_data),
          'output_modalities' => output_modalities_for(model_data),
          'context_length' => integer_value(model_data['context_length'] || model_data.dig('top_provider', 'context_length')),
          'embedding_dimensions' => VECTOR_DIMENSIONS,
          'requested_embedding_dimensions' => VECTOR_DIMENSIONS,
          'pricing' => pricing_for(model_data),
          'latency_ms' => numeric_value(model_data.dig('top_provider', 'latency_ms') || model_data.dig('top_provider', 'latency') ||
                                        model_data['latency_ms'] || model_data['latency']),
          'throughput_tokens_per_second' => numeric_value(model_data.dig('top_provider', 'throughput_tokens_per_second') ||
                                                          model_data.dig('top_provider', 'throughput') ||
                                                          model_data['throughput_tokens_per_second'] || model_data['tokens_per_second'] ||
                                                          model_data['throughput']),
          'description' => model_data['description'].to_s.presence,
          'source' => source
        }.compact
      ]
    end

    def normalize_transcription_model(model_data, source:)
      return unless model_data.is_a?(Hash)

      model_id = model_data['id'].to_s.strip
      return if model_id.blank?
      return unless transcription_output_model?(model_data)

      [
        model_id,
        {
          'provider' => PROVIDER,
          'display_name' => model_data['name'].presence || model_id,
          'credit_multiplier' => 1,
          'type' => 'transcription',
          'capabilities' => transcription_capabilities_for(model_data),
          'input_modalities' => input_modalities_for(model_data),
          'output_modalities' => output_modalities_for(model_data),
          'context_length' => integer_value(model_data['context_length'] || model_data.dig('top_provider', 'context_length')),
          'pricing' => pricing_for(model_data),
          'latency_ms' => numeric_value(model_data.dig('top_provider', 'latency_ms') || model_data.dig('top_provider', 'latency') ||
                                        model_data['latency_ms'] || model_data['latency']),
          'throughput_tokens_per_second' => numeric_value(model_data.dig('top_provider', 'throughput_tokens_per_second') ||
                                                          model_data.dig('top_provider', 'throughput') ||
                                                          model_data['throughput_tokens_per_second'] || model_data['tokens_per_second'] ||
                                                          model_data['throughput']),
          'description' => model_data['description'].to_s.presence,
          'source' => source
        }.compact
      ]
    end

    def normalize_rerank_model(model_data, source:)
      return unless model_data.is_a?(Hash)

      model_id = model_data['id'].to_s.strip
      return if model_id.blank?
      return unless rerank_output_model?(model_data)

      [
        model_id,
        {
          'provider' => PROVIDER,
          'display_name' => model_data['name'].presence || model_id,
          'credit_multiplier' => 1,
          'type' => 'rerank',
          'capabilities' => rerank_capabilities_for(model_data),
          'input_modalities' => input_modalities_for(model_data),
          'output_modalities' => output_modalities_for(model_data),
          'context_length' => integer_value(model_data['context_length'] || model_data.dig('top_provider', 'context_length')),
          'pricing' => pricing_for(model_data),
          'latency_ms' => numeric_value(model_data.dig('top_provider', 'latency_ms') || model_data.dig('top_provider', 'latency') ||
                                        model_data['latency_ms'] || model_data['latency']),
          'throughput_tokens_per_second' => numeric_value(model_data.dig('top_provider', 'throughput_tokens_per_second') ||
                                                          model_data.dig('top_provider', 'throughput') ||
                                                          model_data['throughput_tokens_per_second'] || model_data['tokens_per_second'] ||
                                                          model_data['throughput']),
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
          'input_modalities' => fallback_input_modalities_for(model_data),
          'output_modalities' => fallback_output_modalities_for(model_data),
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

    def embedding_output_model?(model_data)
      output_modalities = output_modalities_for(model_data)
      modality = model_data.dig('architecture', 'modality').to_s

      return output_modalities.include?('embeddings') if output_modalities.present?
      return modality.split('->').last.to_s.include?('embedding') if modality.present?

      false
    end

    def transcription_output_model?(model_data)
      output_modalities = output_modalities_for(model_data)
      modality = model_data.dig('architecture', 'modality').to_s

      return output_modalities.include?('transcription') if output_modalities.present?
      return modality.split('->').last.to_s.include?('transcription') if modality.present?

      false
    end

    def rerank_output_model?(model_data)
      output_modalities = output_modalities_for(model_data)
      modality = model_data.dig('architecture', 'modality').to_s
      configured_capabilities = Array(model_data['capabilities']).map(&:to_s)
      model_type = model_data['type'].to_s

      return true if model_type == 'rerank'
      return true if configured_capabilities.include?('rerank')
      return true if output_modalities.intersect?(%w[rerank ranking rankings])
      return true if modality.split('->').last.to_s.match?(/rerank|rank/)

      false
    end

    def fallback_text_output_model?(model_data)
      output_modalities = Array(model_data.dig('modalities', 'output')).map(&:to_s)
      return output_modalities.include?('text') if output_modalities.present?

      true
    end

    def capabilities_for(model_data)
      input_modalities = input_modalities_for(model_data)
      output_modalities = output_modalities_for(model_data)
      supported_parameters = Array(model_data['supported_parameters']).map(&:to_s)
      capabilities = ['streaming']

      capabilities << 'text_input' if input_modalities.include?('text')
      capabilities << 'text_output' if output_modalities.include?('text')
      capabilities << 'image_input' if input_modalities.include?('image')
      capabilities << 'image_output' if output_modalities.include?('image')
      capabilities << 'audio_input' if input_modalities.include?('audio')
      capabilities << 'audio_output' if output_modalities.include?('audio')
      capabilities << 'file_input' if input_modalities.include?('file')
      capabilities << 'tool_calling' if supported_parameters.intersect?(%w[tools tool_choice])
      capabilities << 'structured_output' if supported_parameters.intersect?(%w[response_format structured_outputs])
      capabilities << 'reasoning' if supported_parameters.intersect?(%w[reasoning reasoning_effort include_reasoning])
      capabilities << 'multimodal_input' if (input_modalities - ['text']).any?
      capabilities << 'transcription' if audio_transcription_model?(model_data)
      capabilities << 'moderation' if moderation_model?(model_data)

      capabilities.uniq
    end

    def embedding_capabilities_for(model_data)
      input_modalities = input_modalities_for(model_data)
      capabilities = ['embedding']

      capabilities << 'text_input' if input_modalities.include?('text')
      capabilities << 'image_input' if input_modalities.include?('image')
      capabilities << 'audio_input' if input_modalities.include?('audio')
      capabilities << 'file_input' if input_modalities.include?('file')
      capabilities << 'multimodal_input' if (input_modalities - ['text']).any?

      capabilities.uniq
    end

    def transcription_capabilities_for(model_data)
      input_modalities = input_modalities_for(model_data)
      supported_parameters = Array(model_data['supported_parameters']).map(&:to_s)
      capabilities = ['transcription']

      capabilities << 'audio_input' if input_modalities.include?('audio')
      capabilities << 'structured_output' if supported_parameters.intersect?(%w[response_format structured_outputs])

      capabilities.uniq
    end

    def rerank_capabilities_for(model_data)
      input_modalities = input_modalities_for(model_data)
      capabilities = %w[rerank text_output]

      capabilities << 'text_input' if input_modalities.blank? || input_modalities.include?('text')
      capabilities.uniq
    end

    def fallback_capabilities_for(model_data)
      input_modalities = fallback_input_modalities_for(model_data)
      output_modalities = fallback_output_modalities_for(model_data)
      configured_capabilities = Array(model_data['capabilities']).map(&:to_s)
      capabilities = ['streaming']

      capabilities << 'text_input' if input_modalities.include?('text')
      capabilities << 'text_output' if output_modalities.include?('text')
      capabilities << 'image_input' if configured_capabilities.include?('vision') || input_modalities.include?('image')
      capabilities << 'image_output' if output_modalities.include?('image')
      capabilities << 'audio_input' if input_modalities.include?('audio')
      capabilities << 'audio_output' if output_modalities.include?('audio')
      capabilities << 'file_input' if input_modalities.include?('file')
      capabilities << 'tool_calling' if configured_capabilities.include?('function_calling') || configured_capabilities.include?('tool_calling')
      capabilities << 'structured_output' if configured_capabilities.intersect?(%w[structured_output response_format json_schema structured_outputs])
      capabilities << 'reasoning' if configured_capabilities.include?('reasoning')
      capabilities << 'multimodal_input' if configured_capabilities.include?('vision') || (input_modalities - ['text']).any?

      capabilities.uniq
    end

    def audio_transcription_model?(model_data)
      model_text(model_data).match?(/transcrib|transcription|whisper|voxtral|gpt-audio|speech[-_ ]?to[-_ ]?text|\bstt\b/)
    end

    def moderation_model?(model_data)
      model_text(model_data).match?(/moderation|safeguard|llama[-_ ]?guard|\bguard\b/)
    end

    def model_text(model_data)
      [
        model_data['id'],
        model_data['name'],
        model_data['description']
      ].compact.join(' ').downcase
    end

    def input_modalities_for(model_data)
      architecture = model_data['architecture'].is_a?(Hash) ? model_data['architecture'] : {}
      Array(architecture['input_modalities']).map(&:to_s).presence || modalities_from_architecture(model_data, :input)
    end

    def output_modalities_for(model_data)
      architecture = model_data['architecture'].is_a?(Hash) ? model_data['architecture'] : {}
      Array(architecture['output_modalities']).map(&:to_s).presence || modalities_from_architecture(model_data, :output)
    end

    def fallback_input_modalities_for(model_data)
      Array(model_data.dig('modalities', 'input')).map(&:to_s)
    end

    def fallback_output_modalities_for(model_data)
      Array(model_data.dig('modalities', 'output')).map(&:to_s)
    end

    def modalities_from_architecture(model_data, direction)
      modality = model_data.dig('architecture', 'modality').to_s
      return [] if modality.blank?

      input, output = modality.split('->', 2)
      selected = direction == :input ? input : output
      selected.to_s.split(/[,+]/).map(&:strip).compact_blank
    end

    def pricing_for(model_data)
      pricing = model_data['pricing'].is_a?(Hash) ? model_data['pricing'] : {}
      pricing.slice(
        'prompt',
        'completion',
        'image',
        'audio',
        'input_audio',
        'output_audio',
        'request',
        'input_cache_read',
        'input_cache_write',
        'internal_reasoning'
      )
             .compact
             .transform_values(&:to_s)
    end

    def fallback_pricing_for(model_data)
      standard_text_pricing = model_data.dig('pricing', 'text_tokens', 'standard') || {}
      input_per_million = decimal_price(standard_text_pricing['input_per_million'] || model_data.dig('metadata', 'cost', 'input'))
      output_per_million = decimal_price(standard_text_pricing['output_per_million'] || model_data.dig('metadata', 'cost', 'output'))
      cache_read_per_million = decimal_price(standard_text_pricing['cached_input_per_million'] || model_data.dig('metadata', 'cost', 'cache_read'))
      cache_write_per_million = decimal_price(standard_text_pricing['cached_input_write_per_million'] || model_data.dig('metadata', 'cost',
                                                                                                                        'cache_write'))

      {
        'prompt' => per_token_price(input_per_million),
        'completion' => per_token_price(output_per_million),
        'input_cache_read' => per_token_price(cache_read_per_million),
        'input_cache_write' => per_token_price(cache_write_per_million)
      }.compact
    end

    def integer_value(value)
      return if value.blank?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def numeric_value(value)
      return if value.blank?

      Float(value)
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
