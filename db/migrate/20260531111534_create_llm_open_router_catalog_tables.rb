require 'digest'

class CreateLlmOpenRouterCatalogTables < ActiveRecord::Migration[7.1]
  LEGACY_MODEL_CATALOG_KEY = 'CAPTAIN_OPENROUTER_MODEL_CATALOG'.freeze
  LEGACY_ENDPOINT_CATALOG_KEY = 'CAPTAIN_OPENROUTER_ENDPOINT_CATALOG'.freeze
  PROVIDER = 'openrouter'.freeze
  VECTOR_DIMENSIONS = 1536

  class MigrationInstallationConfig < ActiveRecord::Base
    self.table_name = 'installation_configs'
  end

  def up
    create_catalog_tables
    backfill_legacy_catalogs
  end

  def down
    drop_table :llm_embedding_model_profiles, if_exists: true
    drop_table :llm_model_endpoint_entries, if_exists: true
    drop_table :llm_model_catalog_entries, if_exists: true
  end

  private

  def create_catalog_tables
    create_table :llm_model_catalog_entries do |t|
      t.string :provider_platform, null: false
      t.string :model_id, null: false
      t.string :canonical_slug
      t.string :display_name, null: false
      t.string :model_type, null: false
      t.jsonb :input_modalities, null: false, default: []
      t.jsonb :output_modalities, null: false, default: []
      t.jsonb :supported_parameters, null: false, default: []
      t.jsonb :capabilities, null: false, default: []
      t.integer :context_length
      t.integer :max_output_tokens
      t.jsonb :pricing, null: false, default: {}
      t.jsonb :top_provider, null: false, default: {}
      t.string :knowledge_cutoff
      t.text :description
      t.jsonb :raw_payload, null: false, default: {}
      t.string :source, null: false, default: 'openrouter_api'
      t.datetime :fetched_at, null: false
      t.datetime :stale_at
      t.datetime :disabled_at
      t.string :checksum

      t.timestamps
    end

    add_index :llm_model_catalog_entries, [:provider_platform, :model_id], unique: true, name: 'idx_llm_model_catalog_provider_model'
    add_index :llm_model_catalog_entries, [:provider_platform, :model_type], name: 'idx_llm_model_catalog_provider_type'
    add_index :llm_model_catalog_entries, [:provider_platform, :disabled_at], name: 'idx_llm_model_catalog_provider_disabled'
    add_index :llm_model_catalog_entries, [:provider_platform, :stale_at], name: 'idx_llm_model_catalog_provider_stale'

    create_table :llm_model_endpoint_entries do |t|
      t.string :provider_platform, null: false
      t.string :model_id, null: false
      t.string :endpoint_slug, null: false
      t.string :endpoint_provider_name
      t.string :endpoint_provider_key
      t.jsonb :supported_parameters, null: false, default: []
      t.jsonb :capabilities, null: false, default: []
      t.integer :context_length
      t.integer :max_prompt_tokens
      t.integer :max_completion_tokens
      t.jsonb :pricing, null: false, default: {}
      t.integer :latency_ms
      t.decimal :throughput_tokens_per_second, precision: 12, scale: 4
      t.decimal :uptime_last_30m, precision: 5, scale: 2
      t.string :quantization
      t.string :data_collection
      t.boolean :zdr
      t.jsonb :raw_payload, null: false, default: {}
      t.datetime :fetched_at, null: false
      t.datetime :stale_at
      t.string :checksum

      t.timestamps
    end

    add_index :llm_model_endpoint_entries,
              [:provider_platform, :model_id, :endpoint_provider_key, :endpoint_slug],
              unique: true,
              name: 'idx_llm_endpoint_provider_model_key_slug'
    add_index :llm_model_endpoint_entries, [:provider_platform, :model_id], name: 'idx_llm_endpoint_provider_model'
    add_index :llm_model_endpoint_entries, [:provider_platform, :endpoint_provider_key], name: 'idx_llm_endpoint_provider_key'
    add_index :llm_model_endpoint_entries, [:provider_platform, :stale_at], name: 'idx_llm_endpoint_provider_stale'

    create_table :llm_embedding_model_profiles do |t|
      t.string :provider_platform, null: false
      t.string :model_id, null: false
      t.integer :default_dimensions
      t.jsonb :supported_dimensions, null: false, default: []
      t.integer :min_dimensions
      t.integer :max_dimensions
      t.boolean :supports_dimension_override, null: false, default: false
      t.boolean :supports_input_type, null: false, default: false
      t.boolean :supports_text_input, null: false, default: false
      t.boolean :supports_image_input, null: false, default: false
      t.string :probe_status
      t.text :probe_error
      t.datetime :probed_at

      t.timestamps
    end

    add_index :llm_embedding_model_profiles, [:provider_platform, :model_id], unique: true, name: 'idx_llm_embedding_profiles_provider_model'
    add_index :llm_embedding_model_profiles, [:provider_platform, :probe_status], name: 'idx_llm_embedding_profiles_provider_status'
  end

  def backfill_legacy_catalogs
    now = Time.current
    model_payload = legacy_payload(LEGACY_MODEL_CATALOG_KEY)
    endpoint_payload = legacy_payload(LEGACY_ENDPOINT_CATALOG_KEY)

    backfill_model_entries(model_payload, now)
    backfill_endpoint_entries(endpoint_payload, now)
    backfill_embedding_profiles(model_payload, now)
  end

  def legacy_payload(key)
    config = MigrationInstallationConfig.find_by(name: key)
    payload = config&.serialized_value
    payload = payload['value'] || payload[:value] if payload.is_a?(Hash) && (payload.key?('value') || payload.key?(:value))
    payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
  rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
    {}
  end

  def backfill_model_entries(payload, now)
    rows = payload.fetch('models', {}).filter_map do |model_id, config|
      next unless config.is_a?(Hash)

      config = config.deep_stringify_keys
      fetched_at = parse_time(payload['last_refreshed_at']) || now
      {
        provider_platform: PROVIDER,
        model_id: model_id.to_s,
        canonical_slug: model_id.to_s.downcase,
        display_name: config['display_name'].presence || model_id.to_s,
        model_type: config['type'].presence || 'chat',
        input_modalities: Array(config['input_modalities']).map(&:to_s),
        output_modalities: Array(config['output_modalities']).map(&:to_s),
        supported_parameters: Array(config['supported_parameters']).map(&:to_s),
        capabilities: Array(config['capabilities']).map(&:to_s),
        context_length: integer_value(config['context_length']),
        max_output_tokens: integer_value(config['max_output_tokens']),
        pricing: hash_value(config['pricing']),
        top_provider: hash_value(config['top_provider']),
        knowledge_cutoff: config['knowledge_cutoff'].to_s.presence,
        description: config['description'].to_s.presence,
        raw_payload: hash_value(config['raw_payload']),
        source: config['source'].presence || 'openrouter_api',
        fetched_at: fetched_at,
        checksum: checksum_for(config),
        created_at: now,
        updated_at: now
      }
    end
    return if rows.blank?

    catalog_entry_class.upsert_all(rows, unique_by: 'idx_llm_model_catalog_provider_model')
  end

  def backfill_endpoint_entries(payload, now)
    rows = payload.fetch('models', {}).flat_map do |model_id, model_config|
      next [] unless model_config.is_a?(Hash)

      Array(model_config['endpoints']).filter_map.with_index do |endpoint, index|
        next unless endpoint.is_a?(Hash)

        endpoint = endpoint.deep_stringify_keys
        fetched_at = parse_time(payload['last_refreshed_at']) || now
        provider_name = endpoint['provider_name'].to_s.presence
        endpoint_slug = endpoint['tag'].to_s.presence || endpoint['name'].to_s.presence || [provider_name, model_id, index].compact.join('/')
        next if endpoint_slug.blank?

        {
          provider_platform: PROVIDER,
          model_id: model_id.to_s,
          endpoint_slug: endpoint_slug,
          endpoint_provider_name: provider_name,
          endpoint_provider_key: endpoint['provider_key'].to_s.presence || provider_name.to_s.parameterize,
          supported_parameters: Array(endpoint['supported_parameters']).map(&:to_s),
          capabilities: Array(endpoint['capabilities']).map(&:to_s),
          context_length: integer_value(endpoint['context_length']),
          max_prompt_tokens: integer_value(endpoint['max_prompt_tokens'] || endpoint['context_length']),
          max_completion_tokens: integer_value(endpoint['max_completion_tokens'] || endpoint['max_output_tokens']),
          pricing: hash_value(endpoint['pricing']),
          latency_ms: integer_value(endpoint['latency_ms']),
          throughput_tokens_per_second: numeric_value(endpoint['throughput_tokens_per_second']),
          uptime_last_30m: numeric_value(endpoint['uptime_last_30m']),
          quantization: endpoint['quantization'].to_s.presence,
          data_collection: endpoint['data_collection'].to_s.presence,
          zdr: boolean_value(endpoint['zdr']),
          raw_payload: hash_value(endpoint['raw_payload']).presence || endpoint,
          fetched_at: fetched_at,
          checksum: checksum_for(endpoint),
          created_at: now,
          updated_at: now
        }
      end
    end
    return if rows.blank?

    rows.uniq! { |row| [row[:provider_platform], row[:model_id], row[:endpoint_provider_key], row[:endpoint_slug]] }
    endpoint_entry_class.upsert_all(rows, unique_by: 'idx_llm_endpoint_provider_model_key_slug')
  end

  def backfill_embedding_profiles(payload, now)
    rows = payload.fetch('models', {}).filter_map do |model_id, config|
      next unless config.is_a?(Hash)

      config = config.deep_stringify_keys
      next unless config['type'].to_s == 'embedding'

      supported_parameters = Array(config['supported_parameters']).map(&:to_s)
      dimensions = Array(config['supported_embedding_dimensions'] || config['supported_dimensions']).filter_map { |value| integer_value(value) }
      dimensions << integer_value(config['embedding_dimensions']) if integer_value(config['embedding_dimensions'])
      dimensions = dimensions.compact.uniq.sort
      compatible = dimensions.include?(VECTOR_DIMENSIONS)
      {
        provider_platform: PROVIDER,
        model_id: model_id.to_s,
        default_dimensions: dimensions.first,
        supported_dimensions: dimensions,
        min_dimensions: dimensions.min,
        max_dimensions: dimensions.max,
        supports_dimension_override: supports_dimension_override?(supported_parameters, dimensions),
        supports_input_type: supported_parameters.include?('input_type'),
        supports_text_input: Array(config['input_modalities']).blank? || Array(config['input_modalities']).map(&:to_s).include?('text'),
        supports_image_input: Array(config['input_modalities']).map(&:to_s).include?('image'),
        probe_status: compatible ? 'catalog_verified' : 'catalog_incompatible',
        probe_error: compatible ? nil : "Catalog metadata does not advertise #{VECTOR_DIMENSIONS}-dimensional embeddings.",
        probed_at: now,
        created_at: now,
        updated_at: now
      }
    end
    return if rows.blank?

    embedding_profile_class.upsert_all(rows, unique_by: 'idx_llm_embedding_profiles_provider_model')
  end

  def catalog_entry_class
    Class.new(ActiveRecord::Base) { self.table_name = 'llm_model_catalog_entries' }
  end

  def supports_dimension_override?(supported_parameters, dimensions)
    supported_parameters.intersect?(%w[dimensions embedding_dimensions supported_dimensions]) || dimensions.length > 1
  end

  def endpoint_entry_class
    Class.new(ActiveRecord::Base) { self.table_name = 'llm_model_endpoint_entries' }
  end

  def embedding_profile_class
    Class.new(ActiveRecord::Base) { self.table_name = 'llm_embedding_model_profiles' }
  end

  def hash_value(value)
    value.is_a?(Hash) ? value.deep_stringify_keys : {}
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

  def parse_time(value)
    Time.zone.parse(value.to_s) if value.present?
  rescue ArgumentError, TypeError
    nil
  end

  def checksum_for(payload)
    Digest::SHA256.hexdigest(JSON.generate(payload.deep_stringify_keys))
  end
end
