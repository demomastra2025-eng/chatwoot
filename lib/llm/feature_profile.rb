# frozen_string_literal: true

class Llm::FeatureProfile
  FEATURE_ALIASES = {
    'assistant' => 'captain_agent',
    'captain' => 'captain_agent',
    'help_center_search' => 'embedding'
  }.freeze

  # A decision feature picks exactly one of the criteria it offers on the native Decisions endpoint (`decisions: true`);
  # only these features may run on a decision model. The router of the agents, the fact-check gate and the inbound
  # triage decide inside a patient turn: their call is bounded by the short timeout of the profile (`strict_timeout`).
  TURN_DECISION_DEFINITION = {
    required_capabilities: %w[decision_classification],
    timeout_seconds: 2,
    strict_timeout: true,
    max_retries: 0,
    streaming: false,
    native_endpoint: '/alpha/decisions',
    structured_output: true,
    response_healing: false,
    reasoning_policy: 'disabled',
    privacy_policy: 'standard',
    cost_policy: 'latency_first',
    fallback_strategy: 'decision_chain',
    decisions: true
  }.freeze

  FEATURE_DEFINITIONS = {
    'captain_agent' => {
      config_feature_key: 'assistant',
      required_capabilities: %w[text_input text_output tool_calling tool_choice structured_output],
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
      required_capabilities: %w[text_input text_output tool_calling tool_choice structured_output],
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
    'outcome_classification' => {
      config_feature_key: 'outcome_classification',
      required_capabilities: %w[text_input text_output structured_output],
      timeout_seconds: 20,
      max_retries: 1,
      streaming: false,
      native_endpoint: nil,
      structured_output: true,
      response_healing: false,
      reasoning_policy: 'disabled',
      privacy_policy: 'standard',
      cost_policy: 'speed_cost',
      fallback_strategy: 'fast_background',
      decisions: true,
      decision_fallback_models: %w[liquid/d1 typesafe/jev-1.14]
    },
    'language_detection' => {
      config_feature_key: 'language_detection',
      required_capabilities: %w[decision_classification],
      timeout_seconds: 8,
      max_retries: 1,
      streaming: false,
      native_endpoint: '/alpha/decisions',
      structured_output: true,
      response_healing: false,
      reasoning_policy: 'disabled',
      privacy_policy: 'standard',
      cost_policy: 'speed_cost',
      fallback_strategy: 'skip',
      decisions: true,
      decision_fallback_models: %w[liquid/d1 respan/span-02]
    },
    'custom_guardrail' => {
      config_feature_key: 'custom_guardrail',
      required_capabilities: %w[decision_classification],
      timeout_seconds: 20,
      max_retries: 0,
      streaming: false,
      native_endpoint: '/alpha/decisions',
      structured_output: true,
      response_healing: false,
      reasoning_policy: 'disabled',
      privacy_policy: 'standard',
      cost_policy: 'guardrail',
      fallback_strategy: 'skip',
      decisions: true,
      decision_fallback_models: %w[liquid/d1 typesafe/jev-1.14]
    },
    'agent_routing' => TURN_DECISION_DEFINITION.merge(config_feature_key: 'agent_routing'),
    'reply_claim_check' => TURN_DECISION_DEFINITION.merge(config_feature_key: 'reply_claim_check', timeout_seconds: 1.5,
                                                          cost_policy: 'guardrail'),
    'fact_check_gate' => TURN_DECISION_DEFINITION.merge(config_feature_key: 'fact_check_gate', cost_policy: 'guardrail'),
    'inbound_triage' => TURN_DECISION_DEFINITION.merge(config_feature_key: 'inbound_triage'),
    # The strong reasoning chat model that decides a routing turn the decision models were not confident about: the same state
    # and criteria, one key of the criteria back as structured output, thinking on. Bounded by its own timeout; no retry.
    'agent_routing_escalation' => {
      config_feature_key: 'agent_routing_escalation',
      required_capabilities: %w[text_input text_output structured_output],
      timeout_seconds: 15,
      max_retries: 0,
      streaming: false,
      native_endpoint: nil,
      structured_output: true,
      response_healing: false,
      reasoning_policy: 'platform',
      privacy_policy: 'standard',
      cost_policy: 'quality',
      fallback_strategy: 'technical_failure'
    },
    # Cuts the patient's message into one fragment per council participant the router chose; no thinking.
    'council_split' => {
      config_feature_key: 'council_split',
      required_capabilities: %w[text_input text_output structured_output],
      timeout_seconds: 4,
      max_retries: 0,
      streaming: false,
      native_endpoint: nil,
      structured_output: true,
      response_healing: false,
      reasoning_policy: 'disabled',
      privacy_policy: 'standard',
      cost_policy: 'latency_first',
      fallback_strategy: 'whole_message'
    },
    'council_edit' => {
      config_feature_key: 'council_edit',
      required_capabilities: %w[text_input text_output structured_output],
      timeout_seconds: 15,
      max_retries: 0,
      streaming: false,
      native_endpoint: nil,
      structured_output: true,
      response_healing: false,
      reasoning_policy: 'disabled',
      privacy_policy: 'standard',
      cost_policy: 'latency_first',
      fallback_strategy: 'part_texts'
    },
    'customer_notice' => {
      config_feature_key: 'customer_notice',
      required_capabilities: %w[text_input text_output],
      timeout_seconds: 8,
      max_retries: 1,
      streaming: false,
      native_endpoint: nil,
      structured_output: false,
      response_healing: false,
      reasoning_policy: 'disabled',
      privacy_policy: 'standard',
      cost_policy: 'latency_first',
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
    # Looks at a customer image once, before it is read (Captain::ImageReading::Router): does it hold significant handwriting. The image
    # travels in the request (a 1024 px JPEG as a data URL), so the request may be larger than a text decision, and the call is bounded
    # by a longer timeout than a decision inside a patient turn; it runs in the background when the image arrives. No fallback model:
    # when it fails, the safe reader reads the image.
    'image_routing' => TURN_DECISION_DEFINITION.merge(
      config_feature_key: 'image_routing',
      timeout_seconds: 8,
      cost_policy: 'speed_cost',
      fallback_strategy: 'skip',
      max_request_bytes: 1_048_576
    ),
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

    # Whether the feature may run on a decision model through Llm::Runtime.decide.
    def decision_feature?(feature)
      FEATURE_DEFINITIONS.dig(normalize_feature(feature), :decisions) == true
    end

    def decision_feature_keys
      FEATURE_DEFINITIONS.filter_map { |feature_key, definition| feature_key if definition[:decisions] == true }
    end

    def equivalent_feature_keys(feature)
      canonical_key = normalize_feature(feature)
      raw_key = feature.to_s.presence
      return [] if canonical_key.blank? && raw_key.blank?

      definition = FEATURE_DEFINITIONS[canonical_key]
      ([canonical_key, raw_key, definition&.dig(:config_feature_key)] + aliases_for(canonical_key))
        .compact
        .map(&:to_s)
        .select(&:present?)
        .uniq
    end

    private

    def aliases_for(canonical_key)
      FEATURE_ALIASES.filter_map { |alias_key, target_key| alias_key if target_key == canonical_key }
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

  def decisions? = definition[:decisions] == true
  # The largest request body of a decision call that carries more than text (nil: the transport default of the client).
  def max_request_bytes = definition[:max_request_bytes]
  # The decision models asked, in order, when the resolved one fails (see Llm::OpenRouterRuntime#decide).
  def decision_fallback_models = Array(definition[:decision_fallback_models])
  def strict_timeout? = definition[:strict_timeout] == true
  def streaming? = definition[:streaming] == true
  def structured_output? = definition[:structured_output] == true
  def response_healing? = definition[:response_healing] == true
end
