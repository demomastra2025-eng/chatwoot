# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

class Llm::OpenRouterEndpointCatalog
  PROVIDER = Llm::OpenRouterModelCatalog::PROVIDER
  DEFAULT_API_BASE = Llm::OpenRouterModelCatalog::DEFAULT_API_BASE
  CACHE_KEY = 'llm/openrouter/endpoint_catalog'
  LAST_REFRESH_AT_CACHE_KEY = 'llm/openrouter/endpoint_catalog/last_refresh_at'
  LAST_REFRESH_ERROR_CACHE_KEY = 'llm/openrouter/endpoint_catalog/last_refresh_error'
  INSTALLATION_CONFIG_KEY = 'CAPTAIN_OPENROUTER_ENDPOINT_CATALOG'
  REQUEST_TIMEOUT_SECONDS = 20
  PARAMETER_CAPABILITIES = {
    'tools' => 'tool_calling',
    'tool_choice' => 'tool_calling',
    'response_format' => 'structured_output',
    'structured_outputs' => 'structured_output',
    'reasoning' => 'reasoning',
    'reasoning_effort' => 'reasoning',
    'include_reasoning' => 'reasoning'
  }.freeze

  class MissingApiKeyError < StandardError; end
  class FetchError < StandardError; end

  class << self
    def refresh!(model_ids: nil, api_key: nil, api_base: nil)
      resolved_api_key = api_key.presence || Llm::Config.api_key(PROVIDER)
      raise MissingApiKeyError, 'OpenRouter API key is not configured.' if resolved_api_key.blank?

      resolved_api_base = api_base.presence || Llm::Config.api_base(PROVIDER) || DEFAULT_API_BASE
      ids = normalize_model_ids(model_ids.presence || Llm::OpenRouterModelCatalog.model_ids)
      timestamp = Time.current.iso8601(6)
      previous_endpoint_configs = refreshed_endpoint_configs.slice(*ids)
      endpoint_configs = {}
      endpoint_errors = {}

      ids.each do |model_id|
        endpoint_configs[model_id] = normalize_endpoint_payload(
          model_id,
          fetch_payload(endpoint_uri(resolved_api_base, model_id)) { |uri| request_for(uri, resolved_api_key) }
        )
      rescue FetchError => e
        endpoint_errors[model_id] = sanitize_error_message(e)
      end

      if endpoint_configs.blank? && endpoint_errors.present?
        message = refresh_failure_message(endpoint_errors)
        persist_refresh_error(message)
        Rails.cache.write(LAST_REFRESH_ERROR_CACHE_KEY, message)
        raise FetchError, message
      end

      endpoint_configs = previous_endpoint_configs.merge(endpoint_configs) if endpoint_errors.present?

      @last_endpoint_configs = endpoint_configs
      @last_refreshed_at = timestamp
      @last_refresh_error = endpoint_errors.presence
      @cached_endpoint_configs = endpoint_configs
      @cached_endpoint_configs_refresh_marker = timestamp
      @cached_endpoint_configs_loaded = true

      persist_endpoint_catalog(endpoint_configs, timestamp, endpoint_errors)
      Rails.cache.write(CACHE_KEY, endpoint_configs)
      Rails.cache.write(LAST_REFRESH_AT_CACHE_KEY, timestamp)
      endpoint_errors.present? ? Rails.cache.write(LAST_REFRESH_ERROR_CACHE_KEY, endpoint_errors) : Rails.cache.delete(LAST_REFRESH_ERROR_CACHE_KEY)

      metadata.merge(last_refreshed_at: timestamp, last_refresh_error: endpoint_errors.presence)
    end

    def sanitize_error_message(error)
      Llm::OpenRouterModelCatalog.sanitize_error_message(error)
    end

    def endpoint_configs
      current_endpoint_configs_snapshot || refreshed_endpoint_configs
    end

    def with_endpoint_configs_snapshot
      previous_snapshot = Thread.current[endpoint_configs_snapshot_key]
      Thread.current[endpoint_configs_snapshot_key] = endpoint_configs
      yield
    ensure
      Thread.current[endpoint_configs_snapshot_key] = previous_snapshot
    end

    def endpoint_metadata(model_name)
      endpoint_configs[Llm::Models.canonical_model_name(model_name)]
    end

    def endpoints_for(model_name)
      Array(endpoint_metadata(model_name).to_h['endpoints'])
    end

    def metadata
      configs = refreshed_endpoint_configs
      persistent_payload = persisted_endpoint_catalog_payload
      {
        total_models: configs.count,
        total_endpoints: configs.values.sum { |config| Array(config['endpoints']).count },
        provider_count: endpoint_provider_names(configs).count,
        providers: endpoint_provider_names(configs),
        source: configs.present? ? 'openrouter_api' : 'not_refreshed',
        last_refreshed_at: Rails.cache.read(LAST_REFRESH_AT_CACHE_KEY) || @last_refreshed_at || persistent_payload['last_refreshed_at'],
        last_refresh_error: Rails.cache.read(LAST_REFRESH_ERROR_CACHE_KEY) || @last_refresh_error || persistent_payload['last_refresh_error']
      }
    end

    private

    def current_endpoint_configs_snapshot
      Thread.current[endpoint_configs_snapshot_key]
    end

    def endpoint_configs_snapshot_key
      :llm_openrouter_endpoint_catalog_endpoint_configs_snapshot
    end

    def fetch_payload(uri)
      response = http_for(uri).request(yield(uri))
      raise FetchError, "OpenRouter endpoints API returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise FetchError, 'OpenRouter endpoints API returned invalid JSON.'
    rescue FetchError
      raise
    rescue StandardError => e
      raise FetchError, "OpenRouter endpoints API request failed: #{sanitize_error_message(e)}"
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

    def endpoint_uri(api_base, model_id)
      author, slug = model_id.to_s.split('/', 2)
      raise FetchError, "OpenRouter model id '#{model_id}' is not provider-prefixed." if author.blank? || slug.blank?

      URI("#{api_root(api_base)}/models/#{escape_path_segment(author)}/#{escape_path_segment(slug)}/endpoints")
    end

    def api_root(api_base)
      api_base.to_s.chomp('/').delete_suffix('/endpoints').delete_suffix('/models')
    end

    def escape_path_segment(segment)
      URI.encode_www_form_component(segment.to_s)
    end

    def normalize_model_ids(model_ids)
      Array(model_ids).map { |model_id| Llm::Models.canonical_model_name(model_id) }.compact_blank.uniq
    end

    def normalize_endpoint_payload(model_id, payload)
      data = payload.is_a?(Hash) ? payload['data'] : nil
      root = data.is_a?(Hash) ? data : payload
      endpoints = root.is_a?(Hash) ? root['endpoints'] : nil
      raise FetchError, 'OpenRouter endpoints API response is missing endpoints array.' unless endpoints.is_a?(Array)

      normalized_endpoints = endpoints.filter_map { |endpoint| normalize_endpoint(endpoint) }
      {
        'model_id' => model_id,
        'endpoint_count' => normalized_endpoints.count,
        'providers' => normalized_endpoints.filter_map { |endpoint| endpoint['provider_name'] }.uniq.sort,
        'endpoints' => normalized_endpoints,
        'source' => 'openrouter_api'
      }
    end

    def normalize_endpoint(endpoint)
      return unless endpoint.is_a?(Hash)

      supported_parameters = Array(endpoint['supported_parameters']).map(&:to_s).uniq
      {
        'name' => endpoint['name'].to_s.presence,
        'provider_name' => endpoint['provider_name'].presence || endpoint.dig('provider', 'name').presence || endpoint['provider'].to_s.presence,
        'tag' => endpoint['tag'].to_s.presence,
        'status' => endpoint['status'].to_s.presence,
        'quantization' => endpoint['quantization'].to_s.presence,
        'context_length' => integer_value(endpoint['context_length'] || endpoint['max_prompt_tokens']),
        'max_output_tokens' => integer_value(endpoint['max_completion_tokens'] || endpoint['max_output_tokens']),
        'supported_parameters' => supported_parameters,
        'capabilities' => endpoint_capabilities(endpoint, supported_parameters),
        'pricing' => pricing_for(endpoint),
        'latency_ms' => numeric_value(endpoint['latency_ms'] || endpoint['latency']),
        'throughput_tokens_per_second' => numeric_value(endpoint['throughput_tokens_per_second'] || endpoint['throughput']),
        'data_collection' => endpoint['data_collection'].to_s.presence,
        'zdr' => boolean_value(endpoint['zdr'] || endpoint['zero_data_retention'])
      }.compact
    end

    def endpoint_capabilities(endpoint, supported_parameters)
      capabilities = ['streaming']
      input_modalities = endpoint_modalities(endpoint, 'input_modalities')
      output_modalities = endpoint_modalities(endpoint, 'output_modalities')

      capabilities << 'text_input' if input_modalities.include?('text')
      capabilities << 'text_output' if output_modalities.include?('text')
      capabilities << 'image_input' if input_modalities.include?('image')
      capabilities << 'audio_input' if input_modalities.include?('audio')
      capabilities << 'file_input' if input_modalities.include?('file')
      capabilities.concat(supported_parameters.filter_map { |parameter| PARAMETER_CAPABILITIES[parameter] })
      capabilities.uniq
    end

    def endpoint_modalities(endpoint, key)
      Array(endpoint[key] || endpoint.dig('architecture', key)).map(&:to_s)
    end

    def pricing_for(endpoint)
      pricing = endpoint['pricing'].is_a?(Hash) ? endpoint['pricing'] : {}
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
      ).compact.transform_values(&:to_s)
    end

    def cached_endpoint_configs
      refresh_marker = Rails.cache.read(LAST_REFRESH_AT_CACHE_KEY)

      if refresh_marker.present? && defined?(@cached_endpoint_configs_loaded) && @cached_endpoint_configs_loaded &&
         @cached_endpoint_configs_refresh_marker == refresh_marker
        return @cached_endpoint_configs
      end

      cached_configs = normalize_cached_endpoint_configs(Rails.cache.read(CACHE_KEY))
      if refresh_marker.present?
        @cached_endpoint_configs = cached_configs
        @cached_endpoint_configs_refresh_marker = refresh_marker
        @cached_endpoint_configs_loaded = true
      end

      cached_configs
    end

    def refreshed_endpoint_configs
      cached_endpoint_configs.presence || persisted_endpoint_configs.presence || in_memory_endpoint_configs
    end

    def in_memory_endpoint_configs
      normalize_cached_endpoint_configs(@last_endpoint_configs)
    end

    def persisted_endpoint_configs
      normalize_cached_endpoint_configs(persisted_endpoint_catalog_payload['models'])
    end

    def persisted_endpoint_catalog_payload
      payload = InstallationConfig.find_by(name: INSTALLATION_CONFIG_KEY)&.value
      payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      {}
    end

    def persist_endpoint_catalog(endpoint_configs, timestamp, endpoint_errors)
      persist_endpoint_catalog_payload(
        'models' => endpoint_configs,
        'last_refreshed_at' => timestamp,
        'last_refresh_error' => endpoint_errors.presence
      )
    end

    def persist_refresh_error(error_message)
      payload = persisted_endpoint_catalog_payload
      payload['last_refresh_error'] = error_message
      persist_endpoint_catalog_payload(payload)
    end

    def persist_endpoint_catalog_payload(payload)
      config = InstallationConfig.find_or_initialize_by(name: INSTALLATION_CONFIG_KEY)
      config.value = payload
      config.locked = false
      config.save!
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      nil
    end

    def normalize_cached_endpoint_configs(cached)
      return {} unless cached.is_a?(Hash)

      cached.each_with_object({}) do |(model_id, config), result|
        next unless config.is_a?(Hash)

        result[model_id.to_s] = config.deep_stringify_keys
      end
    end

    def endpoint_provider_names(configs)
      configs.values.flat_map { |config| Array(config['providers']) }.compact_blank.uniq.sort
    end

    def refresh_failure_message(endpoint_errors)
      first_error = endpoint_errors.values.first
      "OpenRouter endpoints API failed for #{endpoint_errors.count} model(s): #{first_error}"
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

    def boolean_value(value)
      return if value.nil?

      ActiveModel::Type::Boolean.new.cast(value)
    end
  end
end
