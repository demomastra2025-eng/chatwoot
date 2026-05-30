# frozen_string_literal: true

class Llm::OpenRouterRoutingProfile
  RESPONSE_HEALING_PLUGIN_ID = 'response-healing'

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
              :workspace_policy

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
    @workspace_policy = Llm::OpenRouterWorkspacePolicy.resolve(
      account: account,
      preferences: runtime_preferences,
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
      native_endpoint: native_endpoint
    }.compact
  end

  private

  def build_models
    ([model] + FALLBACK_MODELS.fetch(feature_key, [])).compact_blank.uniq
  end

  def build_provider_preferences
    base = workspace_policy.provider_preferences.deep_dup

    case feature_key
    when 'captain_agent', 'moderation'
      base.merge(require_parameters: true)
    when 'copilot'
      base.merge(require_parameters: true, sort: { by: 'latency', partition: 'none' })
    when 'editor', 'label_suggestion'
      base.merge(require_parameters: false, sort: { by: 'price', partition: 'none' })
    else
      base.merge(require_parameters: false)
    end
  end
end
