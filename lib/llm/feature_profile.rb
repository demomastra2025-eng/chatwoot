# frozen_string_literal: true

class Llm::FeatureProfile
  FEATURE_ALIASES = {
    'assistant' => 'captain_agent',
    'captain' => 'captain_agent',
    'help_center_search' => 'embedding'
  }.freeze

  FEATURE_DEFINITIONS = {
    'captain_agent' => {
      config_feature_key: 'assistant',
      required_capabilities: %w[text_input text_output tool_calling structured_output],
      timeout_seconds: 60,
      max_retries: 2,
      streaming: false,
      native_endpoint: nil,
      structured_output: true,
      response_healing: true,
      reasoning_policy: 'user_preference',
      privacy_policy: 'standard',
      cost_policy: 'balanced',
      fallback_strategy: 'short_reliable'
    },
    'copilot' => {
      config_feature_key: 'copilot',
      required_capabilities: %w[text_input text_output tool_calling structured_output],
      timeout_seconds: 45,
      max_retries: 2,
      streaming: false,
      native_endpoint: nil,
      structured_output: true,
      response_healing: true,
      reasoning_policy: 'user_preference',
      privacy_policy: 'standard',
      cost_policy: 'latency_first',
      fallback_strategy: 'short_reliable'
    },
    'editor' => {
      config_feature_key: 'editor',
      required_capabilities: %w[text_input text_output],
      timeout_seconds: 30,
      max_retries: 1,
      streaming: false,
      native_endpoint: nil,
      structured_output: false,
      response_healing: false,
      reasoning_policy: 'disabled',
      privacy_policy: 'standard',
      cost_policy: 'speed_cost',
      fallback_strategy: 'fast_background'
    },
    'label_suggestion' => {
      config_feature_key: 'label_suggestion',
      required_capabilities: %w[text_input text_output],
      timeout_seconds: 30,
      max_retries: 1,
      streaming: false,
      native_endpoint: nil,
      structured_output: false,
      response_healing: false,
      reasoning_policy: 'disabled',
      privacy_policy: 'standard',
      cost_policy: 'speed_cost',
      fallback_strategy: 'fast_background'
    },
    'image_recognition' => {
      config_feature_key: 'image_recognition',
      required_capabilities: %w[text_input text_output image_input],
      timeout_seconds: 45,
      max_retries: 1,
      streaming: false,
      native_endpoint: nil,
      structured_output: false,
      response_healing: false,
      reasoning_policy: 'disabled',
      privacy_policy: 'standard',
      cost_policy: 'balanced',
      fallback_strategy: 'vision_reliable'
    },
    'audio_transcription' => {
      config_feature_key: 'audio_transcription',
      required_capabilities: %w[audio_input transcription],
      timeout_seconds: 120,
      max_retries: 1,
      streaming: false,
      native_endpoint: '/audio/transcriptions',
      structured_output: false,
      response_healing: false,
      reasoning_policy: 'disabled',
      privacy_policy: 'standard',
      cost_policy: 'native_endpoint',
      fallback_strategy: 'native_stt'
    },
    'moderation' => {
      config_feature_key: 'moderation',
      required_capabilities: %w[text_input text_output structured_output moderation],
      timeout_seconds: 20,
      max_retries: 1,
      streaming: false,
      native_endpoint: nil,
      structured_output: true,
      response_healing: false,
      reasoning_policy: 'disabled',
      privacy_policy: 'standard',
      cost_policy: 'guardrail',
      fallback_strategy: 'fail_by_policy'
    },
    'embedding' => {
      config_feature_key: 'help_center_search',
      required_capabilities: %w[embedding],
      timeout_seconds: 60,
      max_retries: 1,
      streaming: false,
      native_endpoint: '/embeddings',
      structured_output: false,
      response_healing: false,
      reasoning_policy: 'disabled',
      privacy_policy: 'standard',
      cost_policy: 'native_endpoint',
      fallback_strategy: 'native_embedding'
    },
    'knowledge_rerank' => {
      config_feature_key: 'knowledge_rerank',
      required_capabilities: %w[text_input text_output rerank],
      timeout_seconds: 45,
      max_retries: 1,
      streaming: false,
      native_endpoint: '/rerank',
      structured_output: false,
      response_healing: false,
      reasoning_policy: 'disabled',
      privacy_policy: 'standard',
      cost_policy: 'quality',
      fallback_strategy: 'skip_rerank'
    }
  }.freeze

  attr_reader :feature_key, :account, :definition

  class << self
    def for(feature, account: nil)
      feature_key = normalize_feature(feature)
      definition = FEATURE_DEFINITIONS[feature_key]
      raise ArgumentError, "Unsupported LLM feature: #{feature}" if definition.blank?

      new(feature_key: feature_key, account: account, definition: definition)
    end

    def normalize_feature(feature)
      key = feature.to_s.presence
      FEATURE_ALIASES.fetch(key, key)
    end

    def supported?(feature)
      FEATURE_DEFINITIONS.key?(normalize_feature(feature))
    end
  end

  def initialize(feature_key:, account:, definition:)
    @feature_key = feature_key
    @account = account
    @definition = definition.deep_dup
  end

  def config_feature_key = definition[:config_feature_key]
  def required_capabilities = Array(definition[:required_capabilities])
  def timeout_seconds = definition[:timeout_seconds]
  def max_retries = definition[:max_retries]
  def native_endpoint = definition[:native_endpoint]
  def reasoning_policy = definition[:reasoning_policy]
  def privacy_policy = definition[:privacy_policy]
  def cost_policy = definition[:cost_policy]
  def fallback_strategy = definition[:fallback_strategy]

  def streaming? = definition[:streaming] == true
  def structured_output? = definition[:structured_output] == true
  def response_healing? = definition[:response_healing] == true
end
