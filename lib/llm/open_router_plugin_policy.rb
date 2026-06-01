# frozen_string_literal: true

class Llm::OpenRouterPluginPolicy
  DENIED_PLUGIN_IDS = %w[
    apply-patch apply_patch openrouter:apply-patch openrouter:apply_patch pareto pareto-router pareto_router
    image-generation image_generation openrouter:image-generation openrouter:image_generation pdf-inputs pdf_inputs
    web web-search web_search openrouter:web-search openrouter:web_search openrouter:web-fetch openrouter:web_fetch
  ].freeze

  RUNTIME_ALLOWLIST_KEYS = %w[
    openrouter_allowed_plugins allowed_openrouter_plugins openrouter_plugin_allowlist
  ].freeze

  Extension = Struct.new(
    :id,
    :kind,
    :product_label_key,
    :allowed_features,
    :risk_level,
    :default_mode,
    :observability_metadata,
    :admin_availability,
    :status,
    :reason,
    :owner,
    :enablement_requirements,
    keyword_init: true
  ) do
    def available_for_feature?(feature)
      allowed_features.include?(Llm::FeatureProfile.normalize_feature(feature).to_s)
    end

    def to_h
      {
        id: id,
        kind: kind,
        product_label_key: product_label_key,
        allowed_features: allowed_features,
        risk_level: risk_level,
        default_mode: default_mode,
        observability_metadata: observability_metadata,
        admin_availability: admin_availability,
        status: status,
        reason: reason,
        owner: owner,
        enablement_requirements: enablement_requirements
      }.compact
    end
  end

  EXTENSION_REGISTRY = {
    'response-healing' => Extension.new(
      id: 'response-healing',
      kind: 'plugin',
      product_label_key: 'structured_response_recovery',
      allowed_features: %w[captain_agent copilot],
      risk_level: 'low',
      default_mode: 'auto_for_non_streaming_structured_output',
      observability_metadata: %w[plugin_id schema_name healing_status],
      admin_availability: 'status_only',
      status: 'implemented',
      reason: 'Repairs malformed JSON only for structured non-streaming requests.'
    ),
    'context-compression' => Extension.new(
      id: 'context-compression',
      kind: 'plugin',
      product_label_key: 'long_context_protection',
      allowed_features: %w[captain_agent copilot],
      risk_level: 'medium',
      default_mode: 'overflow_only',
      observability_metadata: %w[estimated_tokens context_limit transform_reason],
      admin_availability: 'status_only',
      status: 'implemented',
      reason: 'Enabled only by the OneLink overflow policy, never by caller-supplied params.'
    ),
    'openrouter:datetime' => Extension.new(
      id: 'openrouter:datetime',
      kind: 'server_tool',
      product_label_key: 'system_time',
      allowed_features: %w[captain_agent copilot],
      risk_level: 'low',
      default_mode: 'allowlisted',
      observability_metadata: %w[server_tool_id feature],
      admin_availability: 'status_only',
      status: 'implemented',
      reason: 'Safe read-only system time tool for agent context.'
    ),
    'openrouter:web-search' => Extension.new(
      id: 'openrouter:web-search',
      kind: 'server_tool',
      product_label_key: 'web_search',
      allowed_features: [],
      risk_level: 'high',
      default_mode: 'blocked',
      observability_metadata: %w[server_tool_id feature],
      admin_availability: 'locked',
      status: 'deferred',
      reason: 'No approved OneLink product use case yet; would require source policy, cost controls, and content safety review.',
      owner: 'ai-platform',
      enablement_requirements: %w[approved_use_case source_policy cost_budget guardrail_review]
    ),
    'pdf-inputs' => Extension.new(
      id: 'pdf-inputs',
      kind: 'plugin',
      product_label_key: 'pdf_inputs',
      allowed_features: [],
      risk_level: 'medium',
      default_mode: 'blocked',
      observability_metadata: %w[plugin_id feature],
      admin_availability: 'locked',
      status: 'deferred',
      reason: 'Document ingestion must stay in OneLink knowledge indexing until PDF parsing semantics and retention are audited.',
      owner: 'ai-platform',
      enablement_requirements: %w[retention_policy knowledge_indexing_mapping eval_pack]
    ),
    'image-generation' => Extension.new(
      id: 'image-generation',
      kind: 'plugin',
      product_label_key: 'image_generation',
      allowed_features: [],
      risk_level: 'high',
      default_mode: 'blocked',
      observability_metadata: %w[plugin_id feature],
      admin_availability: 'locked',
      status: 'deferred',
      reason: 'OneLink Captain currently consumes multimodal inputs but does not generate media.',
      owner: 'ai-platform',
      enablement_requirements: %w[product_use_case storage_policy moderation_policy]
    )
  }.freeze

  class << self
    def registry
      EXTENSION_REGISTRY.transform_values(&:to_h)
    end

    def deferred_extensions
      EXTENSION_REGISTRY.values.select { |extension| extension.status == 'deferred' }.map(&:to_h)
    end

    def feature_extensions(feature)
      EXTENSION_REGISTRY.values
                        .select { |extension| extension.available_for_feature?(feature) }
                        .map(&:to_h)
    end

    def filter(plugins:, runtime_preferences: nil, default_allowed_ids: [], feature_allowed_ids: nil)
      allowed_ids = allowed_plugin_ids(
        runtime_preferences: runtime_preferences,
        default_allowed_ids: default_allowed_ids,
        feature_allowed_ids: feature_allowed_ids
      )

      filtered = Array(plugins).filter_map do |plugin|
        id = plugin_id(plugin)
        normalized_id = normalize_plugin_id(id)
        next if normalized_id.blank? || denied?(normalized_id)
        next unless allowed_ids.include?(normalized_id)

        normalize_plugin(plugin, normalized_id)
      end

      filtered.uniq { |plugin| plugin_id(plugin).to_s }
    end

    def allowed_plugin_ids(runtime_preferences: nil, default_allowed_ids: [], feature_allowed_ids: nil)
      allowed_ids = (normalize_ids(default_allowed_ids) + runtime_allowed_plugin_ids(runtime_preferences)).uniq
      allowed_ids &= normalize_ids(feature_allowed_ids) unless feature_allowed_ids.nil?

      allowed_ids - DENIED_PLUGIN_IDS
    end

    def runtime_allowed_plugin_ids(runtime_preferences)
      preferences = normalize_preferences(runtime_preferences)
      RUNTIME_ALLOWLIST_KEYS.flat_map { |key| normalize_ids(preferences[key]) }.uniq
    end

    private

    def normalize_preferences(runtime_preferences)
      return {} unless runtime_preferences.respond_to?(:to_h)

      runtime_preferences.to_h.deep_stringify_keys
    rescue StandardError
      {}
    end

    def normalize_ids(value)
      Array(value).filter_map { |entry| normalize_plugin_id(entry).presence }.uniq
    end

    def plugin_id(plugin)
      return plugin if plugin.is_a?(String) || plugin.is_a?(Symbol)
      return plugin[:id] || plugin['id'] if plugin.respond_to?(:[])

      plugin
    rescue StandardError
      nil
    end

    def normalize_plugin_id(value)
      value.to_s.strip.tr('_', '-').presence
    end

    def denied?(plugin_id)
      DENIED_PLUGIN_IDS.include?(plugin_id)
    end

    def normalize_plugin(plugin, plugin_id)
      return { id: plugin_id } unless plugin.respond_to?(:to_h)

      plugin.to_h.deep_symbolize_keys.merge(id: plugin_id)
    rescue StandardError
      { id: plugin_id }
    end
  end
end
