# frozen_string_literal: true

require 'digest'
require 'json'
require 'net/http'
require 'uri'
require 'securerandom'

class Llm::OpenRouterEndpointCatalog
  PROVIDER = Llm::OpenRouterModelCatalog::PROVIDER
  DEFAULT_API_BASE = Llm::OpenRouterModelCatalog::DEFAULT_API_BASE
  CACHE_KEY = 'llm/openrouter/endpoint_catalog'
  LAST_REFRESH_AT_CACHE_KEY = 'llm/openrouter/endpoint_catalog/last_refresh_at'
  LAST_REFRESH_ERROR_CACHE_KEY = 'llm/openrouter/endpoint_catalog/last_refresh_error'
  INSTALLATION_CONFIG_KEY = 'CAPTAIN_OPENROUTER_ENDPOINT_CATALOG'
  REQUEST_TIMEOUT_SECONDS = 20
  RUNNING_REFRESH_STALE_AFTER = 30.minutes
  REFRESH_LOCK_ID = 5_310_102
  DEFAULT_REFRESH_BATCH_SIZE = 50
  DEFAULT_REFRESH_THROTTLE_SECONDS = 0.25
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
  class RefreshAlreadyRunningError < StandardError; end

  class << self
    def refresh!(model_ids: nil, api_key: nil, api_base: nil, limit: DEFAULT_REFRESH_BATCH_SIZE, throttle_seconds: DEFAULT_REFRESH_THROTTLE_SECONDS)
      resolved_api_key = api_key.presence || Llm::Config.api_key(PROVIDER)
      raise MissingApiKeyError, 'OpenRouter API key is not configured.' if resolved_api_key.blank?

      resolved_api_base = api_base.presence || Llm::Config.api_base(PROVIDER) || DEFAULT_API_BASE
      all_ids = normalize_model_ids(model_ids.presence || Llm::OpenRouterModelCatalog.model_ids)
      ids = endpoint_refresh_batch(all_ids, limit: limit)
      lock_acquired = acquire_refresh_lock
      raise RefreshAlreadyRunningError, 'OpenRouter endpoint catalog refresh is already running.' unless lock_acquired

      started_at = Time.current.iso8601(6)
      refresh_id = SecureRandom.uuid
      persist_refresh_started(started_at, refresh_id: refresh_id)
      timestamp = Time.current.iso8601(6)
      all_previous_endpoint_configs = refreshed_endpoint_configs
      previous_endpoint_configs = all_previous_endpoint_configs.slice(*ids)
      endpoint_configs = {}
      endpoint_errors = {}

      ids.each_with_index do |model_id, index|
        endpoint_configs[model_id] = normalize_endpoint_payload(
          model_id,
          fetch_payload(endpoint_uri(resolved_api_base, model_id)) { |uri| request_for(uri, resolved_api_key) }
        )
      rescue FetchError => e
        endpoint_errors[model_id] = sanitize_error_message(e)
      ensure
        throttle_endpoint_refresh(throttle_seconds) if index < ids.length - 1
      end

      if endpoint_configs.blank? && endpoint_errors.present?
        message = refresh_failure_message(endpoint_errors)
        persist_refresh_error(message, started_at: started_at, refresh_id: refresh_id)
        Rails.cache.write(LAST_REFRESH_ERROR_CACHE_KEY, message)
        raise FetchError, message
      end

      diff = catalog_diff(previous_endpoint_configs, endpoint_configs, failed_model_ids: endpoint_errors.keys)
      endpoint_configs = all_previous_endpoint_configs.merge(endpoint_configs)
      pending_model_ids = all_ids - endpoint_configs.keys

      @last_endpoint_configs = endpoint_configs
      @last_refreshed_at = timestamp
      @last_refresh_error = endpoint_errors.presence
      @cached_endpoint_configs = endpoint_configs
      @cached_endpoint_configs_refresh_marker = timestamp
      @cached_endpoint_configs_loaded = true

      persist_endpoint_catalog(
        endpoint_configs,
        timestamp,
        endpoint_errors,
        refreshed_model_ids: ids,
        started_at: started_at,
        refresh_id: refresh_id,
        diff: diff,
        pending_model_ids: pending_model_ids
      )
      Rails.cache.write(CACHE_KEY, endpoint_configs)
      Rails.cache.write(LAST_REFRESH_AT_CACHE_KEY, timestamp)
      endpoint_errors.present? ? Rails.cache.write(LAST_REFRESH_ERROR_CACHE_KEY, endpoint_errors) : Rails.cache.delete(LAST_REFRESH_ERROR_CACHE_KEY)

      metadata.merge(
        last_refreshed_at: timestamp,
        last_started_at: started_at,
        last_finished_at: timestamp,
        refresh_status: refresh_status(endpoint_errors, pending_model_ids),
        last_refresh_error: endpoint_errors.presence,
        last_refresh_diff: diff,
        refreshed_model_ids: ids,
        pending_model_ids: pending_model_ids,
        pending_model_count: pending_model_ids.count
      )
    ensure
      release_refresh_lock if defined?(lock_acquired) && lock_acquired
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
      last_refreshed_at = Rails.cache.read(LAST_REFRESH_AT_CACHE_KEY) || @last_refreshed_at || persistent_payload['last_refreshed_at']
      last_refresh_error = Rails.cache.read(LAST_REFRESH_ERROR_CACHE_KEY) || @last_refresh_error || persistent_payload['last_refresh_error']
      {
        total_models: configs.count,
        total_endpoints: configs.values.sum { |config| Array(config['endpoints']).count },
        provider_count: endpoint_provider_names(configs).count,
        providers: endpoint_provider_names(configs),
        source: configs.present? ? 'openrouter_api' : 'not_refreshed',
        stale_endpoints: db_stale_endpoint_count,
        last_refreshed_at: last_refreshed_at,
        last_started_at: persistent_payload['last_started_at'],
        last_finished_at: persistent_payload['last_finished_at'] || last_refreshed_at,
        refresh_status: refresh_status_for_payload(persistent_payload, last_refreshed_at, last_refresh_error),
        last_refresh_error: last_refresh_error,
        last_refresh_diff: persistent_payload['last_refresh_diff'] || empty_refresh_diff,
        refreshed_model_ids: persistent_payload['refreshed_model_ids'] || [],
        pending_model_ids: persistent_payload['pending_model_ids'] || [],
        pending_model_count: (persistent_payload['pending_model_count'] || 0).to_i
      }
    end

    private

    def acquire_refresh_lock
      return true unless postgresql_connection?

      ActiveModel::Type::Boolean.new.cast(
        ActiveRecord::Base.connection.select_value("SELECT pg_try_advisory_lock(#{REFRESH_LOCK_ID})")
      )
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      true
    end

    def release_refresh_lock
      return unless postgresql_connection?

      ActiveRecord::Base.connection.select_value("SELECT pg_advisory_unlock(#{REFRESH_LOCK_ID})")
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      nil
    end

    def postgresql_connection?
      ActiveRecord::Base.connection.adapter_name.to_s.downcase.include?('postgres')
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      false
    end

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

    def endpoint_refresh_batch(model_ids, limit:)
      return model_ids if limit.blank?

      batch_limit = Integer(limit)
      return [] if batch_limit <= 0
      return model_ids if model_ids.count <= batch_limit

      known_configs = refreshed_endpoint_configs
      missing_ids, known_ids = model_ids.partition { |model_id| known_configs[model_id].blank? }
      selected_missing_ids = missing_ids.first(batch_limit)
      selected_missing_ids + oldest_endpoint_model_ids(known_ids, limit: batch_limit - selected_missing_ids.count)
    rescue ArgumentError, TypeError
      model_ids
    end

    def oldest_endpoint_model_ids(model_ids, limit:)
      return [] if limit <= 0
      return model_ids.first(limit) unless endpoint_table_available?

      fetched_at_by_model = Llm::ModelEndpointEntry.openrouter.where(model_id: model_ids).group(:model_id).minimum(:fetched_at)
      model_ids.sort_by { |model_id| fetched_at_by_model[model_id] || Time.zone.at(0) }.first(limit)
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      model_ids.first(limit)
    end

    def throttle_endpoint_refresh(throttle_seconds)
      seconds = Float(throttle_seconds)
      sleep(seconds) if seconds.positive?
    rescue ArgumentError, TypeError
      nil
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
        'provider_key' => endpoint_provider_key(endpoint),
        'tag' => endpoint['tag'].to_s.presence,
        'status' => endpoint['status'].to_s.presence,
        'quantization' => endpoint['quantization'].to_s.presence,
        'context_length' => integer_value(endpoint['context_length'] || endpoint['max_prompt_tokens']),
        'max_prompt_tokens' => integer_value(endpoint['max_prompt_tokens'] || endpoint['context_length']),
        'max_completion_tokens' => integer_value(endpoint['max_completion_tokens'] || endpoint['max_output_tokens']),
        'max_output_tokens' => integer_value(endpoint['max_completion_tokens'] || endpoint['max_output_tokens']),
        'supported_parameters' => supported_parameters,
        'capabilities' => endpoint_capabilities(endpoint, supported_parameters),
        'pricing' => pricing_for(endpoint),
        'latency_ms' => numeric_value(endpoint['latency_ms'] || endpoint['latency']),
        'throughput_tokens_per_second' => numeric_value(endpoint['throughput_tokens_per_second'] || endpoint['throughput']),
        'uptime_last_30m' => numeric_value(endpoint['uptime_last_30m'] || endpoint['uptime']),
        'data_collection' => endpoint['data_collection'].to_s.presence,
        'zdr' => boolean_value(endpoint['zdr'] || endpoint['zero_data_retention']),
        'raw_payload' => endpoint.deep_stringify_keys
      }.compact
    end

    def endpoint_provider_key(endpoint)
      endpoint['provider_key'].to_s.presence ||
        endpoint['provider_name'].to_s.parameterize.presence ||
        endpoint.dig('provider', 'name').to_s.parameterize.presence ||
        endpoint['provider'].to_s.parameterize.presence
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
      db_endpoint_configs.presence || normalize_cached_endpoint_configs(legacy_persisted_endpoint_catalog_payload['models'])
    end

    def persisted_endpoint_catalog_payload
      db_configs = db_endpoint_configs
      legacy_payload = legacy_persisted_endpoint_catalog_payload
      if db_configs.present?
        return legacy_payload.merge(
          'models' => db_configs,
          'last_refreshed_at' => db_last_refreshed_at || legacy_payload['last_refreshed_at'],
          'last_refresh_error' => legacy_payload['last_refresh_error']
        )
      end

      legacy_payload
    end

    def legacy_persisted_endpoint_catalog_payload
      payload = InstallationConfig.find_by(name: INSTALLATION_CONFIG_KEY)&.value
      payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      {}
    end

    def db_endpoint_configs
      return {} unless endpoint_table_available?

      Llm::ModelEndpointEntry.openrouter.servable.fresh_first.group_by(&:model_id).transform_values do |entries|
        endpoint_config_for_entries(entries)
      end
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      {}
    end

    def endpoint_config_for_entries(entries)
      endpoints = entries.map(&:to_openrouter_endpoint)
      {
        'model_id' => entries.first.model_id,
        'endpoint_count' => endpoints.count,
        'providers' => entries.filter_map(&:endpoint_provider_name).uniq.sort,
        'endpoints' => endpoints,
        'source' => 'openrouter_api'
      }
    end

    def db_last_refreshed_at
      return unless endpoint_table_available?

      Llm::ModelEndpointEntry.openrouter.maximum(:fetched_at)&.iso8601(6)
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      nil
    end

    def db_stale_endpoint_count
      return 0 unless endpoint_table_available?

      Llm::ModelEndpointEntry.openrouter.where.not(stale_at: nil).count
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      0
    end

    def refresh_status_for_payload(payload, last_refreshed_at, last_refresh_error)
      status = payload['refresh_status'].to_s.presence
      return 'stale_running' if status == 'running' && running_refresh_stale?(payload['last_started_at'])

      status || inferred_refresh_status(last_refreshed_at, last_refresh_error)
    end

    def running_refresh_stale?(started_at)
      parsed_started_at = Time.zone.parse(started_at.to_s) if started_at.present?
      parsed_started_at.present? && parsed_started_at < RUNNING_REFRESH_STALE_AFTER.ago
    rescue ArgumentError, TypeError
      false
    end

    def inferred_refresh_status(last_refreshed_at, last_refresh_error)
      return 'partial_success' if last_refreshed_at.present? && last_refresh_error.present?
      return 'failed' if last_refresh_error.present?
      return 'success' if last_refreshed_at.present?

      'not_refreshed'
    end

    def empty_refresh_diff
      {
        'new' => [],
        'changed' => [],
        'removed' => [],
        'provider_changed' => [],
        'price_changed' => [],
        'failed_model_ids' => []
      }
    end

    def catalog_diff(previous_configs, current_configs, failed_model_ids: [])
      previous_by_key = endpoint_entries_by_key(previous_configs.except(*failed_model_ids))
      current_by_key = endpoint_entries_by_key(current_configs)
      previous_keys = previous_by_key.keys
      current_keys = current_by_key.keys
      shared_keys = previous_keys & current_keys
      changed_keys = shared_keys.reject do |endpoint_key|
        checksum_for(previous_by_key[endpoint_key]) == checksum_for(current_by_key[endpoint_key])
      end
      affected_model_ids = (previous_configs.keys + current_configs.keys).uniq - failed_model_ids.map(&:to_s)

      empty_refresh_diff.merge(
        'new' => (current_keys - previous_keys).sort,
        'changed' => changed_keys.sort,
        'removed' => (previous_keys - current_keys).sort,
        'provider_changed' => affected_model_ids.filter_map do |model_id|
          provider_diff_for(model_id, previous_configs[model_id], current_configs[model_id])
        end,
        'price_changed' => price_changed_endpoint_keys(changed_keys, previous_by_key, current_by_key),
        'failed_model_ids' => failed_model_ids.map(&:to_s).sort
      )
    end

    def price_changed_endpoint_keys(changed_keys, previous_by_key, current_by_key)
      changed_keys.reject do |endpoint_key|
        pricing_signature(previous_by_key[endpoint_key]) == pricing_signature(current_by_key[endpoint_key])
      end.sort
    end

    def endpoint_entries_by_key(configs)
      normalize_cached_endpoint_configs(configs).each_with_object({}) do |(model_id, config), result|
        Array(config['endpoints']).each_with_index do |endpoint, index|
          endpoint = comparable_endpoint_payload(model_id, endpoint.to_h.deep_stringify_keys, index)
          endpoint_key = endpoint_diff_key(model_id, endpoint, index)
          result[endpoint_key] = endpoint if endpoint_key.present?
        end
      end
    end

    def comparable_endpoint_payload(model_id, endpoint, index)
      endpoint = endpoint.except('raw_payload')
      endpoint['provider_key'] = endpoint_provider_key(endpoint)
      endpoint['tag'] = endpoint['tag'].presence || endpoint['name'].presence ||
                        synthetic_endpoint_slug(model_id, endpoint, index)
      endpoint
    end

    def synthetic_endpoint_slug(model_id, endpoint, index)
      provider_name = endpoint['provider_name'].to_s.presence ||
                      endpoint.dig('provider', 'name').to_s.presence ||
                      endpoint['provider'].to_s.presence
      [provider_name, model_id, index].compact.join('/')
    end

    def endpoint_diff_key(model_id, endpoint, index)
      provider_key = endpoint['provider_key'].to_s.presence ||
                     endpoint['provider_name'].to_s.parameterize.presence ||
                     'unknown-provider'
      endpoint_slug = endpoint['tag'].to_s.presence || endpoint['name'].to_s.presence || index.to_s
      [model_id, provider_key, endpoint_slug].join('|')
    end

    def provider_diff_for(model_id, previous_config, current_config)
      previous_providers = Array(previous_config.to_h['providers']).map(&:to_s).sort
      current_providers = Array(current_config.to_h['providers']).map(&:to_s).sort
      return if previous_providers == current_providers

      {
        'model_id' => model_id,
        'added' => current_providers - previous_providers,
        'removed' => previous_providers - current_providers
      }
    end

    def pricing_signature(endpoint)
      (endpoint.to_h['pricing'].is_a?(Hash) ? endpoint.to_h['pricing'].deep_stringify_keys : {}).sort.to_h
    end

    def persist_endpoint_catalog(
      endpoint_configs,
      timestamp,
      endpoint_errors,
      refreshed_model_ids:,
      started_at:,
      refresh_id:,
      diff:,
      pending_model_ids: []
    )
      persist_endpoint_catalog_entries(endpoint_configs.slice(*refreshed_model_ids), timestamp, endpoint_errors)
      persist_endpoint_catalog_payload_if_current(
        {
          'models' => endpoint_configs,
          'last_started_at' => started_at,
          'last_finished_at' => timestamp,
          'last_refreshed_at' => timestamp,
          'refresh_status' => refresh_status(endpoint_errors, pending_model_ids),
          'refresh_id' => refresh_id,
          'last_refresh_error' => endpoint_errors.presence,
          'last_refresh_diff' => diff,
          'refreshed_model_ids' => refreshed_model_ids,
          'pending_model_ids' => pending_model_ids,
          'pending_model_count' => pending_model_ids.count
        },
        refresh_id: refresh_id
      )
    end

    def refresh_status(endpoint_errors, pending_model_ids)
      return 'partial_success' if endpoint_errors.present?
      return 'incremental_pending' if pending_model_ids.present?

      'success'
    end

    def persist_endpoint_catalog_entries(endpoint_configs, timestamp, endpoint_errors)
      return unless endpoint_table_available?

      fetched_at = timestamp_time(timestamp)
      now = Time.current
      failed_model_ids = endpoint_errors.keys.map(&:to_s)
      rows = endpoint_configs.except(*failed_model_ids).flat_map do |model_id, model_config|
        Array(model_config['endpoints']).filter_map.with_index do |endpoint, index|
          endpoint_entry_attributes(model_id.to_s, endpoint.deep_stringify_keys, index, fetched_at, now)
        end
      end
      rows.uniq! { |row| [row[:provider_platform], row[:model_id], row[:endpoint_provider_key], row[:endpoint_slug]] }
      Llm::ModelEndpointEntry.upsert_all(rows, unique_by: 'idx_llm_endpoint_provider_model_key_slug') if rows.present?
      refreshed_model_ids = endpoint_configs.keys.map(&:to_s) - failed_model_ids
      return if refreshed_model_ids.blank?

      Llm::ModelEndpointEntry.openrouter
                             .where(model_id: refreshed_model_ids)
                             .where.not(fetched_at: fetched_at)
                             .update_all(stale_at: fetched_at, updated_at: now)
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      nil
    end

    def endpoint_entry_attributes(model_id, endpoint, index, fetched_at, now)
      provider_name = endpoint['provider_name'].to_s.presence || endpoint.dig('provider', 'name').to_s.presence || endpoint['provider'].to_s.presence
      endpoint_slug = endpoint['tag'].to_s.presence || endpoint['name'].to_s.presence || [provider_name, model_id, index].compact.join('/')
      return if endpoint_slug.blank?

      max_prompt_tokens = integer_value(endpoint['max_prompt_tokens'] || endpoint['context_length'])
      max_completion_tokens = integer_value(endpoint['max_completion_tokens'] || endpoint['max_output_tokens'])
      {
        provider_platform: PROVIDER,
        model_id: model_id,
        endpoint_slug: endpoint_slug,
        endpoint_provider_name: provider_name,
        endpoint_provider_key: endpoint['provider_key'].to_s.presence || provider_name.to_s.parameterize,
        supported_parameters: Array(endpoint['supported_parameters']).map(&:to_s).uniq,
        capabilities: Array(endpoint['capabilities']).map(&:to_s).uniq,
        context_length: integer_value(endpoint['context_length'] || max_prompt_tokens),
        max_prompt_tokens: max_prompt_tokens,
        max_completion_tokens: max_completion_tokens,
        pricing: endpoint['pricing'].is_a?(Hash) ? endpoint['pricing'].deep_stringify_keys : {},
        latency_ms: integer_value(endpoint['latency_ms']),
        throughput_tokens_per_second: numeric_value(endpoint['throughput_tokens_per_second']),
        uptime_last_30m: numeric_value(endpoint['uptime_last_30m'] || endpoint['uptime']),
        quantization: endpoint['quantization'].to_s.presence,
        data_collection: endpoint['data_collection'].to_s.presence,
        zdr: boolean_value(endpoint['zdr']),
        raw_payload: endpoint['raw_payload'].is_a?(Hash) ? endpoint['raw_payload'].deep_stringify_keys : endpoint,
        fetched_at: fetched_at,
        stale_at: nil,
        checksum: checksum_for(endpoint),
        created_at: now,
        updated_at: now
      }
    end

    def persist_refresh_started(started_at, refresh_id:)
      payload = persisted_endpoint_catalog_payload
      payload['last_started_at'] = started_at
      payload['refresh_status'] = 'running'
      payload['refresh_id'] = refresh_id
      payload.delete('last_refresh_error')
      persist_endpoint_catalog_payload(payload)
    end

    def persist_refresh_error(error_message, started_at: nil, refresh_id: nil)
      payload = persisted_endpoint_catalog_payload
      payload['last_started_at'] ||= started_at if started_at.present?
      payload['last_finished_at'] = Time.current.iso8601(6)
      payload['refresh_status'] = 'failed'
      payload['refresh_id'] = refresh_id if refresh_id.present?
      payload['last_refresh_error'] = error_message
      persist_endpoint_catalog_payload_if_current(payload, refresh_id: refresh_id)
    end

    def persist_endpoint_catalog_payload_if_current(payload, refresh_id: nil)
      return persist_endpoint_catalog_payload(payload) if refresh_id.blank?

      current_refresh_id = legacy_persisted_endpoint_catalog_payload['refresh_id']
      return false if current_refresh_id.present? && current_refresh_id != refresh_id

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

    def endpoint_table_available?
      defined?(Llm::ModelEndpointEntry) && Llm::ModelEndpointEntry.table_exists?
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      false
    end

    def timestamp_time(timestamp)
      timestamp.is_a?(Time) ? timestamp : Time.iso8601(timestamp.to_s)
    rescue ArgumentError, TypeError
      Time.current
    end

    def checksum_for(payload)
      Digest::SHA256.hexdigest(JSON.generate(canonical_payload(payload)))
    end

    def canonical_payload(value)
      case value
      when Hash
        value.deep_stringify_keys.sort.to_h.transform_values { |nested_value| canonical_payload(nested_value) }
      when Array
        value.map { |nested_value| canonical_payload(nested_value) }
      else
        value
      end
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
