# frozen_string_literal: true

class Llm::FeatureRequest
  IMAGE_EXTENSIONS = %w[.gif .jpeg .jpg .png .webp].freeze
  AUDIO_EXTENSIONS = %w[.aac .flac .m4a .mp3 .mp4 .mpeg .mpga .oga .ogg .wav .webm].freeze
  ACCOUNT_OPTIONAL_FEATURES = %w[moderation].freeze
  TOOL_CHOICE_VALUES = %w[auto none required].freeze
  READ_ONLY_RISK_LEVELS = %w[low read_only readonly lookup].freeze
  MUTATING_RISK_LEVELS = %w[medium high critical destructive custom].freeze
  TOOL_DEFINITION_METHODS = %i[tool_definition definition metadata].freeze
  TOOL_READ_ONLY_KEYS = %i[read_only read_only_hint readonly lookup].freeze
  TOOL_MUTATING_KEYS = %i[mutating mutation destructive destructive_hint side_effect side_effects].freeze
  TOOL_NON_IDEMPOTENT_KEYS = %i[non_idempotent non_retryable].freeze
  BOOLEAN = ActiveModel::Type::Boolean.new

  attr_reader :feature, :account, :assistant, :conversation, :session_id, :user_id, :model, :models,
              :messages, :schema, :tools, :tool_choice, :parallel_tool_calls, :stream, :reasoning,
              :max_tokens, :temperature, :attachments, :input, :runtime_preferences, :privacy_profile,
              :performance_profile, :cost_profile, :routing_intent, :observability, :options

  def initialize(
    feature:,
    account: nil,
    assistant: nil,
    conversation: nil,
    session_id: nil,
    user_id: nil,
    model: nil,
    models: [],
    messages: [],
    schema: nil,
    tools: [],
    tool_choice: nil,
    parallel_tool_calls: nil,
    stream: nil,
    reasoning: nil,
    max_tokens: nil,
    temperature: nil,
    attachments: [],
    input: nil,
    runtime_preferences: {},
    privacy_profile: nil,
    performance_profile: nil,
    cost_profile: nil,
    routing_intent: nil,
    observability: {},
    options: {}
  )
    @feature = feature
    @account = account
    @assistant = assistant
    @conversation = conversation
    @model = model
    @models = normalize_models(models)
    @messages = Array(messages)
    @schema = schema
    @tools = Array(tools)
    @attachments = Array(attachments)
    @input = input
    @runtime_preferences = normalize_hash(runtime_preferences)
    @observability = normalize_hash(observability)
    @options = normalize_hash(options)
    @session_id = normalize_identifier(first_present(session_id, @options[:session_id], @observability[:session_id], derived_session_id))
    @user_id = normalize_identifier(first_present(user_id, @options[:user_id], @options[:user], @observability[:user_id]))
    @tool_choice = normalize_tool_choice(first_non_nil(tool_choice, @options[:tool_choice]))
    @stream = normalize_optional_boolean(first_non_nil(stream, @options[:stream]))
    @reasoning = normalize_reasoning(first_non_nil(reasoning, @options[:reasoning], @options[:thinking]))
    @max_tokens = normalize_integer(first_non_nil(max_tokens, @options[:max_tokens], @options[:max_completion_tokens]))
    @temperature = first_non_nil(temperature, @options[:temperature])
    @performance_profile = normalize_policy_value(first_present(performance_profile, @runtime_preferences[:performance_profile]))
    @cost_profile = normalize_policy_value(first_present(cost_profile, @runtime_preferences[:cost_profile]))
    @routing_intent = normalize_policy_value(first_present(routing_intent, @runtime_preferences[:routing_intent]))
    @privacy_profile = Llm::OpenRouterWorkspacePolicy.resolve(
      account: account,
      preferences: @runtime_preferences,
      privacy_profile: privacy_profile
    ).privacy_profile
    @parallel_tool_calls = normalize_parallel_tool_calls(first_non_nil(parallel_tool_calls, @options[:parallel_tool_calls]))

    validate!
  end

  def feature_key
    @feature_key ||= Llm::FeatureProfile.normalize_feature(feature)
  end

  def profile
    @profile ||= Llm::FeatureProfile.for(feature_key, account: account)
  end

  def account_id
    return unless account.respond_to?(:id)

    account.id
  end

  def requires_tools?
    tools.present?
  end

  def requires_schema?
    schema_required?
  end

  def schema_required?
    schema.present?
  end

  def reasoning?
    reasoning_requested?
  end

  def reasoning_requested?
    reasoning.present?
  end

  def mutating_tool_flow?
    tools.present? && tools.any? { |tool| mutating_tool?(tool) }
  end

  def read_only_tool_flow?
    tools.present? && tools.all? { |tool| read_only_tool?(tool) }
  end

  def native_endpoint_preferred?
    return optional_boolean(options[:native_endpoint]) if options.key?(:native_endpoint)
    return false if messages.present? || options[:chat].present?

    profile.native_endpoint.present?
  end

  def session_cache_key
    return if session_id.blank?

    ['llm', feature_key, account_id, session_id].compact.join(':')
  end

  def multimodal?
    audio? || image? || attachments.present?
  end

  def audio?
    feature_key == 'audio_transcription' || reference_has_extension?(AUDIO_EXTENSIONS)
  end

  def image?
    feature_key == 'image_recognition' || reference_has_extension?(IMAGE_EXTENSIONS)
  end

  private

  def validate!
    validate_feature!
    validate_account!
    validate_schema!
    validate_tools!
  end

  def validate_feature!
    raise ArgumentError, 'LLM feature is required.' if feature.to_s.blank?
    raise ArgumentError, "Unsupported LLM feature: #{feature}" unless Llm::FeatureProfile.supported?(feature)
  end

  def validate_account!
    return if account.present?
    return if ACCOUNT_OPTIONAL_FEATURES.include?(feature_key)

    raise ArgumentError, 'account is required for account-scoped LLM feature requests.'
  end

  def validate_schema!
    return if schema.blank?
    return if ruby_llm_schema_class?(schema)
    return if schema.respond_to?(:to_json_schema) || schema.respond_to?(:json_schema)

    raise ArgumentError, 'schema must be RubyLLM-compatible.'
  end

  def validate_tools!
    invalid_tool = tools.find { |tool| !tool_compatible?(tool) }
    return if invalid_tool.blank?

    raise ArgumentError, 'tools must be RubyLLM-compatible.'
  end

  def ruby_llm_schema_class?(candidate)
    return false unless defined?(RubyLLM::Schema)
    return false unless candidate.is_a?(Class)

    candidate <= RubyLLM::Schema
  end

  def tool_compatible?(tool)
    return false if tool.is_a?(String) || tool.is_a?(Hash)
    return true if ruby_llm_tool?(tool)
    return true if tool.respond_to?(:call) || tool.respond_to?(:name)

    false
  end

  def ruby_llm_tool?(candidate)
    return false unless defined?(RubyLLM::Tool)
    return true if candidate.is_a?(RubyLLM::Tool)
    return candidate <= RubyLLM::Tool if candidate.is_a?(Class)

    false
  rescue StandardError
    false
  end

  def normalize_hash(value)
    return {} unless value.respond_to?(:to_h)

    value.to_h.deep_symbolize_keys
  end

  def normalize_models(value)
    Array(value).filter_map { |candidate| candidate.to_s.strip.presence }.uniq
  end

  def normalize_tool_choice(value)
    return if value.blank?
    return value.to_s if value.is_a?(Symbol)
    return value if value.is_a?(String) && (TOOL_CHOICE_VALUES.include?(value) || value.present?)
    return value.to_h.deep_symbolize_keys if value.respond_to?(:to_h)

    value
  end

  def normalize_parallel_tool_calls(value)
    return if value.nil?
    return false unless optional_boolean(value)

    !mutating_tool_flow?
  end

  def normalize_optional_boolean(value)
    return if value.nil?

    optional_boolean(value)
  end

  def optional_boolean(value)
    BOOLEAN.cast(value)
  end

  def normalize_reasoning(value)
    return if value.blank?
    return value.to_h.deep_symbolize_keys if value.respond_to?(:to_h)

    value
  end

  def normalize_integer(value)
    return if value.blank?

    Integer(value)
  rescue ArgumentError, TypeError
    value
  end

  def normalize_policy_value(value)
    value.to_s.presence
  end

  def normalize_identifier(value)
    value.to_s.presence
  end

  def first_present(*values)
    values.find { |value| value.to_s.present? }
  end

  def first_non_nil(*values)
    values.find { |value| !value.nil? }
  end

  def derived_session_id
    display_id = object_attribute(conversation, :display_id)
    return "#{account_id}_#{display_id}" if account_id.present? && display_id.present?

    conversation_id = object_attribute(conversation, :id)
    return "#{account_id}_conversation_#{conversation_id}" if account_id.present? && conversation_id.present?

    object_attribute(conversation, :id)
  end

  def object_attribute(object, key)
    return if object.blank?
    return object[key] || object[key.to_s] if object.respond_to?(:[])
    return object.public_send(key) if object.respond_to?(key)
  rescue StandardError
    nil
  end

  def reference_has_extension?(extensions)
    reference_values.any? do |value|
      path = value.respond_to?(:path) ? value.path : value
      extension = File.extname(path.to_s.split('?').first.to_s.downcase)
      extensions.include?(extension)
    end
  end

  def reference_values
    Array(input) + attachments
  end

  def mutating_tool?(tool)
    metadata = tool_metadata(tool)
    return true if metadata.empty?
    return true if metadata_boolean(metadata, *TOOL_MUTATING_KEYS) == true
    return true if metadata_boolean(metadata, *TOOL_NON_IDEMPOTENT_KEYS) == true
    return true if metadata_boolean(metadata, :idempotent) == false && metadata_key?(metadata, :idempotent)

    risk_level = metadata[:risk_level].to_s
    return true if MUTATING_RISK_LEVELS.include?(risk_level)
    return false if read_only_tool?(tool)

    true
  end

  def read_only_tool?(tool)
    metadata = tool_metadata(tool)
    return false if metadata.empty?
    return true if metadata_boolean(metadata, *TOOL_READ_ONLY_KEYS) == true

    READ_ONLY_RISK_LEVELS.include?(metadata[:risk_level].to_s)
  end

  def tool_metadata(tool)
    metadata = TOOL_DEFINITION_METHODS.filter_map do |method_name|
      next unless tool.respond_to?(method_name, true)

      tool.send(method_name)
    rescue StandardError
      nil
    end.find(&:present?)

    metadata ||= tool.to_h if metadata.blank? && tool.respond_to?(:to_h) && !tool.is_a?(Hash)
    return {} unless metadata.respond_to?(:to_h)

    metadata.to_h.deep_symbolize_keys
  rescue StandardError
    {}
  end

  def metadata_key?(metadata, *keys)
    keys.any? { |key| metadata.key?(key) || metadata.key?(key.to_s) }
  end

  def metadata_boolean(metadata, *keys)
    key = keys.find { |candidate| metadata.key?(candidate) || metadata.key?(candidate.to_s) }
    return if key.blank?

    value = metadata.key?(key) ? metadata[key] : metadata[key.to_s]
    BOOLEAN.cast(value)
  end
end
