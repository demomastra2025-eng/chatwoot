# frozen_string_literal: true

class Llm::OpenRouterFeaturePolicy
  SERVICE_TIERS = %w[auto flex priority].freeze
  SERVICE_TIER_ALLOWLIST = {
    'captain_agent' => %w[auto priority],
    'copilot' => %w[auto priority],
    'editor' => %w[flex],
    'label_suggestion' => %w[flex],
    'image_recognition' => %w[auto priority],
    'moderation' => %w[priority],
    'embedding' => %w[flex auto],
    'knowledge_rerank' => %w[flex auto]
  }.freeze
  CACHE_POLICY_ALLOWLIST = {
    'captain_agent' => %w[session disabled],
    'copilot' => %w[session disabled],
    'editor' => %w[read_only disabled],
    'label_suggestion' => %w[read_only disabled],
    'image_recognition' => %w[disabled],
    'audio_transcription' => %w[disabled],
    'moderation' => %w[disabled],
    'embedding' => %w[static_context disabled],
    'knowledge_rerank' => %w[read_only disabled]
  }.freeze
  DEFAULT_SERVER_TOOL_ID = 'openrouter:datetime'
  DENIED_SERVER_TOOL_IDS = %w[
    openrouter:apply_patch openrouter:image_generation
  ].freeze
  SERVER_TOOL_ID_ALIASES = {
    'datetime' => DEFAULT_SERVER_TOOL_ID,
    'openrouter:datetime' => DEFAULT_SERVER_TOOL_ID,
    'web-fetch' => 'openrouter:web_fetch',
    'web_fetch' => 'openrouter:web_fetch',
    'openrouter:web-fetch' => 'openrouter:web_fetch',
    'openrouter:web_fetch' => 'openrouter:web_fetch',
    'web-search' => 'openrouter:web_search',
    'web_search' => 'openrouter:web_search',
    'openrouter:web-search' => 'openrouter:web_search',
    'openrouter:web_search' => 'openrouter:web_search',
    'apply-patch' => 'openrouter:apply_patch',
    'apply_patch' => 'openrouter:apply_patch',
    'openrouter:apply-patch' => 'openrouter:apply_patch',
    'openrouter:apply_patch' => 'openrouter:apply_patch',
    'image-generation' => 'openrouter:image_generation',
    'image_generation' => 'openrouter:image_generation',
    'openrouter:image-generation' => 'openrouter:image_generation',
    'openrouter:image_generation' => 'openrouter:image_generation'
  }.freeze

  DEFAULT_POLICY = {
    allowed_plugins: [],
    allowed_server_tools: [],
    allowed_variants: [],
    cache_policy: 'disabled',
    plugin_policy: 'deny_by_default',
    service_tier: nil,
    transform_policy: 'disabled',
    privacy_policy: 'account_profile',
    guardrail_profile: 'standard',
    budget_policy: 'local_ledger',
    observability_mode: 'metadata_only'
  }.freeze

  FEATURE_POLICIES = {
    'captain_agent' => {
      allowed_plugins: %w[response-healing context-compression],
      allowed_server_tools: [DEFAULT_SERVER_TOOL_ID],
      allowed_variants: %w[exacto extended thinking],
      cache_policy: 'session',
      plugin_policy: 'structured_output_and_overflow_only',
      service_tier: nil,
      transform_policy: 'overflow_only',
      guardrail_profile: 'crm_tool_mutation_safe',
      budget_policy: 'local_ledger_hard_stop'
    },
    'copilot' => {
      allowed_plugins: %w[response-healing context-compression],
      allowed_server_tools: [DEFAULT_SERVER_TOOL_ID],
      allowed_variants: %w[exacto nitro thinking],
      cache_policy: 'session',
      plugin_policy: 'structured_output_and_overflow_only',
      service_tier: nil,
      transform_policy: 'overflow_only',
      guardrail_profile: 'assistant_tool_safe',
      budget_policy: 'local_ledger_hard_stop'
    },
    'editor' => {
      allowed_variants: %w[nitro],
      cache_policy: 'read_only',
      service_tier: 'flex',
      guardrail_profile: 'read_only_text'
    },
    'label_suggestion' => {
      allowed_variants: %w[nitro],
      cache_policy: 'read_only',
      service_tier: 'flex',
      guardrail_profile: 'read_only_text'
    },
    'image_recognition' => {
      allowed_variants: %w[nitro extended],
      cache_policy: 'disabled',
      guardrail_profile: 'multimodal_input_safe'
    },
    'audio_transcription' => {
      cache_policy: 'disabled',
      guardrail_profile: 'native_transcription_only'
    },
    'moderation' => {
      cache_policy: 'disabled',
      privacy_policy: 'sensitive_or_account_profile',
      guardrail_profile: 'moderation_evaluation_required',
      budget_policy: 'policy_fail_mode'
    },
    'embedding' => {
      cache_policy: 'static_context',
      guardrail_profile: 'embedding_dimension_safe',
      budget_policy: 'local_ledger_feature_cap'
    },
    'knowledge_rerank' => {
      cache_policy: 'read_only',
      guardrail_profile: 'retrieval_quality_degraded_fallback',
      budget_policy: 'local_ledger_feature_cap'
    }
  }.freeze

  RUNTIME_POLICY_KEYS = {
    cache_policy: %i[cache_policy openrouter_cache_policy],
    plugin_policy: %i[plugin_policy openrouter_plugin_policy],
    service_tier: %i[service_tier openrouter_service_tier],
    transform_policy: %i[transform_policy openrouter_transform_policy],
    privacy_policy: %i[privacy_policy openrouter_privacy_policy],
    guardrail_profile: %i[guardrail_profile openrouter_guardrail_profile],
    budget_policy: %i[budget_policy openrouter_budget_policy],
    observability_mode: %i[observability_mode openrouter_observability_mode],
    allowed_variants: %i[variant_policy openrouter_variant_policy allowed_variants openrouter_allowed_variants]
  }.freeze

  Policy = Struct.new(
    :feature_key,
    :privacy_profile,
    :allowed_plugins,
    :allowed_server_tools,
    :allowed_variants,
    :cache_policy,
    :plugin_policy,
    :service_tier,
    :transform_policy,
    :privacy_policy,
    :guardrail_profile,
    :budget_policy,
    :observability_mode,
    :workspace_policy,
    :runtime_preferences,
    keyword_init: true
  ) do
    def compiled_service_tier
      Llm::OpenRouterFeaturePolicy.compiled_service_tier(service_tier, feature_key: feature_key)
    end

    def filter_plugins(plugins:, runtime_preferences: nil, default_allowed_ids: [])
      Llm::OpenRouterPluginPolicy.filter(
        plugins: plugins,
        runtime_preferences: runtime_preferences,
        default_allowed_ids: default_allowed_ids,
        feature_allowed_ids: allowed_plugins
      )
    end

    def filter_server_tools(server_tools)
      Llm::OpenRouterFeaturePolicy.filter_server_tools(
        server_tools,
        allowed_ids: allowed_server_tools
      )
    end

    def guardrails
      {
        provider_model: guardrail('policy_enforced', 'Feature-specific provider/model routing is compiled through OpenRouterRequestCompiler.'),
        budget: guardrail(budget_guardrail_status, budget_policy),
        plugins: guardrail(plugin_guardrail_status, plugin_policy, allowed: allowed_plugins),
        server_tools: guardrail(
          server_tool_guardrail_status,
          'OpenRouter server tools require feature policy allowlist.',
          allowed: allowed_server_tools
        ),
        variants: guardrail(variant_guardrail_status, 'Only transient policy-approved model variants are allowed.', allowed: allowed_variants),
        privacy: guardrail(privacy_guardrail_status, privacy_policy, privacy_profile: privacy_profile),
        prompt_injection: guardrail(
          runtime_guardrail_status(:prompt_injection),
          'Prompt-injection filters run in OneLink SafetyPolicy before provider dispatch.'
        ),
        pii: guardrail(
          runtime_guardrail_status(:sensitive_info),
          'Credential and secret leakage filters run in OneLink SafetyPolicy before provider dispatch.'
        )
      }
    end

    def extensions
      Llm::OpenRouterPluginPolicy.feature_extensions(feature_key)
    end

    def to_h
      {
        feature_key: feature_key,
        privacy_profile: privacy_profile,
        allowed_plugins: allowed_plugins,
        allowed_server_tools: allowed_server_tools,
        allowed_variants: allowed_variants,
        cache_policy: cache_policy,
        plugin_policy: plugin_policy,
        service_tier: service_tier,
        compiled_service_tier: compiled_service_tier,
        transform_policy: transform_policy,
        privacy_policy: privacy_policy,
        guardrail_profile: guardrail_profile,
        budget_policy: budget_policy,
        observability_mode: observability_mode,
        runtime_preferences: runtime_preferences,
        extensions: extensions,
        guardrails: guardrails
      }.compact
    end

    private

    def guardrail(status, enforcement, details = {})
      { status: status, enforcement: enforcement, details: details.compact }
    end

    def budget_guardrail_status
      budget_policy.to_s.include?('hard_stop') || budget_policy.to_s.include?('cap') ? 'local_enforced' : 'policy_declared'
    end

    def plugin_guardrail_status
      allowed_plugins.present? ? 'allowlist_enforced' : 'blocked_by_default'
    end

    def server_tool_guardrail_status
      allowed_server_tools.present? ? 'allowlist_enforced' : 'blocked_by_default'
    end

    def variant_guardrail_status
      allowed_variants.present? ? 'transient_only' : 'blocked_by_default'
    end

    def privacy_guardrail_status
      workspace_policy&.zdr_required? ? 'zdr_fail_closed' : 'workspace_policy_enforced'
    end

    def runtime_guardrail_status(guardrail)
      action = Llm::RuntimePolicy.guardrail_action(
        guardrail: guardrail,
        feature: runtime_guardrail_feature_key,
        preferences: runtime_guardrail_preferences
      )
      case action
      when 'block'
        'local_enforced'
      when 'flag'
        'local_monitored'
      else
        'disabled'
      end
    end

    def runtime_guardrail_preferences
      runtime_preferences || {}
    end

    def runtime_guardrail_feature_key
      feature_key.to_s == 'captain_agent' ? 'assistant' : feature_key
    end
  end

  class << self
    def for(feature:, account: nil, runtime_preferences: nil, privacy_profile: nil)
      feature_key = Llm::FeatureProfile.normalize_feature(feature)
      preferences = normalize_preferences(runtime_preferences)
      workspace_policy = Llm::OpenRouterWorkspacePolicy.resolve(
        account: account,
        preferences: preferences,
        privacy_profile: privacy_profile
      )
      definition = policy_definition(feature_key, preferences)

      Policy.new(
        feature_key: feature_key,
        privacy_profile: workspace_policy.privacy_profile,
        workspace_policy: workspace_policy,
        allowed_plugins: normalize_plugin_ids(definition[:allowed_plugins]),
        allowed_server_tools: normalize_server_tool_ids(definition[:allowed_server_tools]) - DENIED_SERVER_TOOL_IDS,
        allowed_variants: normalize_variant_ids(definition[:allowed_variants]),
        cache_policy: definition[:cache_policy],
        plugin_policy: definition[:plugin_policy],
        service_tier: definition[:service_tier],
        transform_policy: definition[:transform_policy],
        privacy_policy: definition[:privacy_policy],
        guardrail_profile: definition[:guardrail_profile],
        budget_policy: definition[:budget_policy],
        observability_mode: definition[:observability_mode],
        runtime_preferences: preferences
      )
    end

    def compiled_service_tier(value, feature_key: nil)
      normalized = value.to_s.strip.presence
      return unless SERVICE_TIERS.include?(normalized)
      return normalized if feature_key.blank?

      SERVICE_TIER_ALLOWLIST.fetch(feature_key, []).include?(normalized) ? normalized : nil
    end

    def filter_server_tools(server_tools, allowed_ids:)
      allowed = normalize_server_tool_ids(allowed_ids) - DENIED_SERVER_TOOL_IDS
      return [] if allowed.blank?

      filtered = Array(server_tools).filter_map do |tool|
        id = normalize_server_tool_id(server_tool_id(tool))
        next if id.blank? || DENIED_SERVER_TOOL_IDS.include?(id)
        next unless allowed.include?(id)

        normalize_server_tool(tool, id)
      end

      filtered.uniq { |tool| server_tool_id(tool).to_s }
    end

    def normalize_server_tool_id(value)
      normalized = value.to_s.strip.presence
      return if normalized.blank?

      SERVER_TOOL_ID_ALIASES.fetch(normalized, normalized)
    end

    private

    def policy_definition(feature_key, preferences)
      definition = DEFAULT_POLICY.deep_merge(FEATURE_POLICIES.fetch(feature_key, {}))

      RUNTIME_POLICY_KEYS.except(:service_tier, :allowed_variants).each do |policy_key, preference_keys|
        override = first_present_preference(preferences, preference_keys)
        next if override.blank?

        definition[policy_key] = if policy_key == :cache_policy
                                   constrained_cache_policy(override, feature_key, definition[policy_key])
                                 else
                                   override
                                 end
      end

      variant_override = first_present_preference(preferences, RUNTIME_POLICY_KEYS[:allowed_variants])
      if variant_override.present?
        definition[:allowed_variants] = normalize_variant_ids(definition[:allowed_variants]) &
                                        normalize_variant_ids(variant_override)
      end

      service_tier_override = first_present_preference(preferences, RUNTIME_POLICY_KEYS[:service_tier])
      definition[:service_tier] = compiled_service_tier(service_tier_override, feature_key: feature_key) ||
                                  compiled_service_tier(definition[:service_tier], feature_key: feature_key)
      definition
    end

    def normalize_preferences(runtime_preferences)
      return {} unless runtime_preferences.respond_to?(:to_h)

      runtime_preferences.to_h.deep_symbolize_keys
    rescue StandardError
      {}
    end

    def first_present_preference(preferences, keys)
      keys.filter_map { |key| preferences[key].presence }.first
    end

    def constrained_cache_policy(value, feature_key, fallback)
      normalized = value.to_s.strip.presence
      return fallback if normalized.blank?

      CACHE_POLICY_ALLOWLIST.fetch(feature_key, %w[disabled]).include?(normalized) ? normalized : fallback
    end

    def normalize_plugin_ids(values)
      Array(values).filter_map { |value| normalize_plugin_id(value).presence }.uniq
    end

    def normalize_plugin_id(value)
      value.to_s.strip.tr('_', '-')
    end

    def normalize_server_tool_ids(values)
      Array(values).filter_map { |value| normalize_server_tool_id(value).presence }.uniq
    end

    def normalize_variant_ids(values)
      Array(values).filter_map { |value| value.to_s.strip.tr('_', '-').presence }.uniq
    end

    def server_tool_id(tool)
      return tool if tool.is_a?(String) || tool.is_a?(Symbol)
      return unless tool.respond_to?(:to_h)

      hash = tool.to_h.with_indifferent_access
      hash[:type] || hash[:id] || hash[:name] || hash.dig(:function, :name)
    rescue StandardError
      nil
    end

    def normalize_server_tool(_tool, id)
      { type: id }
    end
  end
end
