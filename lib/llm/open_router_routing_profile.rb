# frozen_string_literal: true

class Llm::OpenRouterRoutingProfile
  RESPONSE_HEALING_PLUGIN_ID = 'response-healing'
  BALANCED_STRATEGY = 'balanced'
  EXACTO_STRATEGY = 'exacto'
  AUTO_EXACTO_STRATEGY = 'auto_exacto'
  LOW_LATENCY_STRATEGY = 'low_latency'
  LOW_COST_STRATEGY = 'low_cost'
  STRICT_TOOLS_STRATEGY = 'strict_tools'
  ZDR_STRICT_STRATEGY = 'zdr_strict'
  ROUTING_STRATEGIES = [
    BALANCED_STRATEGY,
    EXACTO_STRATEGY,
    AUTO_EXACTO_STRATEGY,
    LOW_LATENCY_STRATEGY,
    LOW_COST_STRATEGY,
    STRICT_TOOLS_STRATEGY,
    ZDR_STRICT_STRATEGY
  ].freeze
  ROUTING_STRATEGY_KEYS = %w[openrouter_routing_strategy routing_strategy].freeze
  PROVIDER_ORDER_KEYS = %w[openrouter_provider_order provider_order].freeze
  PROVIDER_RUNTIME_PREFERENCE_KEYS = {
    'openrouter_provider_only' => :only,
    'provider_only' => :only,
    'openrouter_provider_ignore' => :ignore,
    'provider_ignore' => :ignore,
    'openrouter_provider_quantizations' => :quantizations,
    'provider_quantizations' => :quantizations,
    'openrouter_sort' => :sort,
    'provider_sort' => :sort,
    'openrouter_preferred_min_throughput' => :preferred_min_throughput,
    'preferred_min_throughput' => :preferred_min_throughput,
    'openrouter_preferred_max_latency' => :preferred_max_latency,
    'preferred_max_latency' => :preferred_max_latency,
    'openrouter_max_price' => :max_price,
    'max_price' => :max_price,
    'openrouter_enforce_distillable_text' => :enforce_distillable_text,
    'enforce_distillable_text' => :enforce_distillable_text,
    'openrouter_allow_fallbacks' => :allow_fallbacks,
    'openrouter_require_parameters' => :require_parameters,
    'openrouter_zdr' => :zdr,
    'openrouter_data_collection' => :data_collection
  }.freeze

  FEATURE_ALIASES = {
    'assistant' => 'captain_agent',
    'captain' => 'captain_agent',
    'captain_agent' => 'captain_agent',
    'help_center_search' => 'embedding'
  }.freeze

  FALLBACK_MODELS = {
    'captain_agent' => %w[openai/gpt-5.4-mini openai/gpt-5.4],
    'copilot' => %w[openai/gpt-5.4-mini],
    'editor' => %w[openai/gpt-5.4-mini openai/gpt-4.1-mini],
    'label_suggestion' => %w[openai/gpt-5.4-mini openai/gpt-4.1-mini],
    'image_recognition' => %w[openai/gpt-5.4-mini openai/gpt-5.4],
    'audio_transcription' => %w[openai/gpt-4o-mini-transcribe openai/gpt-audio-mini],
    'moderation' => %w[openai/gpt-oss-safeguard-20b],
    'embedding' => %w[text-embedding-3-small],
    'knowledge_rerank' => []
  }.freeze

  NATIVE_ENDPOINTS = {
    'audio_transcription' => '/audio/transcriptions',
    'embedding' => '/embeddings',
    'knowledge_rerank' => '/rerank'
  }.freeze

  attr_reader :feature_key, :model, :account, :models, :provider_preferences, :plugins, :headers, :native_endpoint,
              :workspace_policy, :runtime_preferences

  class << self
    def for(feature:, model: nil, account: nil, runtime_preferences: nil, privacy_profile: nil)
      feature_key = normalize_feature(feature)
      new(
        feature_key: feature_key,
        model: model,
        account: account,
        runtime_preferences: runtime_preferences,
        privacy_profile: privacy_profile
      )
    end

    def normalize_feature(feature)
      key = feature.to_s.presence || 'captain_agent'
      FEATURE_ALIASES.fetch(key, key)
    end
  end

  def initialize(feature_key:, model: nil, account: nil, runtime_preferences: nil, privacy_profile: nil)
    @feature_key = feature_key
    @model = model.to_s.presence
    @account = account
    @runtime_preferences = normalize_runtime_preferences(runtime_preferences)
    @workspace_policy = Llm::OpenRouterWorkspacePolicy.resolve(
      account: account,
      preferences: @runtime_preferences,
      privacy_profile: privacy_profile
    )
    @models = build_models
    @provider_preferences = build_provider_preferences
    @plugins = []
    @headers = {}
    @native_endpoint = NATIVE_ENDPOINTS[feature_key]
  end

  def fallback_models
    models.drop(model.present? ? 1 : 0)
  end

  def response_healing?
    native_endpoint.blank?
  end

  def to_h
    {
      models: models.presence,
      provider: provider_preferences.presence,
      plugins: plugins.presence,
      headers: headers.presence,
      native_endpoint: native_endpoint,
      routing_policy: routing_policy.presence
    }.compact
  end

  def routing_policy
    {
      strategy: routing_strategy.presence,
      provider_order: provider_order.presence,
      allow_fallbacks: provider_preferences[:allow_fallbacks],
      require_parameters: provider_preferences[:require_parameters],
      sort: provider_preferences[:sort],
      preferred_min_throughput: provider_preferences[:preferred_min_throughput],
      preferred_max_latency: provider_preferences[:preferred_max_latency],
      max_price: provider_preferences[:max_price],
      data_collection: provider_preferences[:data_collection],
      zdr: provider_preferences[:zdr]
    }.compact
  end

  private

  def build_models
    ([model] + FALLBACK_MODELS.fetch(feature_key, [])).compact_blank.uniq
  end

  def build_provider_preferences
    base = workspace_policy.provider_preferences.deep_dup

    feature_preferences = case feature_key
                          when 'captain_agent', 'moderation'
                            { require_parameters: true }
                          when 'copilot'
                            { require_parameters: true, sort: { by: 'latency', partition: 'none' } }
                          when 'editor', 'label_suggestion'
                            { require_parameters: false, sort: { by: 'price', partition: 'none' } }
                          else
                            { require_parameters: false }
                          end

    apply_routing_strategy(base.merge(feature_preferences).merge(runtime_provider_preferences)).tap do |provider_preferences|
      enforce_workspace_privacy!(provider_preferences)
    end
  end

  def normalize_runtime_preferences(preferences)
    return {} unless preferences.respond_to?(:to_h)

    preferences.to_h.deep_stringify_keys
  rescue StandardError
    {}
  end

  def runtime_provider_preferences
    PROVIDER_RUNTIME_PREFERENCE_KEYS.each_with_object({}) do |(preference_key, provider_key), result|
      next unless runtime_preferences.key?(preference_key)

      value = normalize_provider_preference_value(provider_key, runtime_preferences[preference_key])
      result[provider_key] = value unless value.nil?
    end
  end

  def normalize_provider_preference_value(provider_key, value)
    case provider_key
    when :only, :ignore, :quantizations
      Array(value).filter_map { |entry| entry.to_s.strip.presence }.presence
    when :allow_fallbacks, :require_parameters, :zdr, :enforce_distillable_text
      ActiveModel::Type::Boolean.new.cast(value)
    when :preferred_min_throughput, :preferred_max_latency
      numeric_provider_preference(value)
    else
      return value.to_h.deep_symbolize_keys if value.respond_to?(:to_h)

      value.presence
    end
  end

  def numeric_provider_preference(value)
    return if value.blank?

    Float(value)
  rescue ArgumentError, TypeError
    value
  end

  def enforce_workspace_privacy!(provider_preferences)
    workspace_preferences = workspace_policy.provider_preferences
    provider_preferences[:data_collection] = workspace_preferences[:data_collection] if workspace_preferences[:data_collection].present?
    return unless workspace_policy.zdr_required?

    provider_preferences[:zdr] = true
    provider_preferences[:allow_fallbacks] = false
  end

  def apply_routing_strategy(provider_preferences)
    order = provider_order

    case routing_strategy
    when EXACTO_STRATEGY
      return provider_preferences if order.blank?

      provider_preferences.except(:sort).merge(order: order, allow_fallbacks: false)
    when AUTO_EXACTO_STRATEGY
      return provider_preferences if order.blank?

      provider_preferences.except(:sort).merge(order: order, allow_fallbacks: true)
    when LOW_LATENCY_STRATEGY
      provider_preferences.merge(sort: { by: 'latency', partition: 'none' })
    when LOW_COST_STRATEGY
      provider_preferences.merge(sort: { by: 'price', partition: 'none' })
    when STRICT_TOOLS_STRATEGY
      provider_preferences.except(:sort).merge(require_parameters: true)
    when ZDR_STRICT_STRATEGY
      provider_preferences.except(:sort).merge(
        data_collection: 'deny',
        zdr: true,
        allow_fallbacks: false
      )
    else
      order.present? ? provider_preferences.merge(order: order) : provider_preferences
    end
  end

  def routing_strategy
    ROUTING_STRATEGY_KEYS.filter_map { |key| runtime_preferences[key].to_s.presence }.first.to_s.tr('-', '_')
  end

  def provider_order
    PROVIDER_ORDER_KEYS.each do |key|
      order = Array(runtime_preferences[key]).map { |provider| provider.to_s.strip }.compact_blank
      return order if order.present?
    end

    []
  end
end
