# frozen_string_literal: true

class Llm::FeatureRequest
  IMAGE_EXTENSIONS = %w[.gif .jpeg .jpg .png .webp].freeze
  AUDIO_EXTENSIONS = %w[.aac .flac .m4a .mp3 .mp4 .mpeg .mpga .oga .ogg .wav .webm].freeze

  attr_reader :feature, :account, :assistant, :model, :messages, :schema, :tools, :attachments, :input,
              :runtime_preferences, :privacy_profile, :observability, :options

  def initialize(
    feature:,
    account: nil,
    assistant: nil,
    model: nil,
    messages: [],
    schema: nil,
    tools: [],
    attachments: [],
    input: nil,
    runtime_preferences: {},
    privacy_profile: nil,
    observability: {},
    options: {}
  )
    @feature = feature
    @account = account
    @assistant = assistant
    @model = model
    @messages = Array(messages)
    @schema = schema
    @tools = Array(tools)
    @attachments = Array(attachments)
    @input = input
    @runtime_preferences = normalize_hash(runtime_preferences)
    @privacy_profile = Llm::OpenRouterWorkspacePolicy.resolve(
      account: account,
      preferences: @runtime_preferences,
      privacy_profile: privacy_profile
    ).privacy_profile
    @observability = normalize_hash(observability)
    @options = normalize_hash(options)

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
    schema.present?
  end

  def reasoning?
    option_present?(:reasoning) || option_present?(:thinking)
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
    raise ArgumentError, 'account is required for account-scoped LLM feature requests.' if account.blank?
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

  def option_present?(key)
    options[key].present? || options[key.to_s].present?
  end

  def normalize_hash(value)
    return {} unless value.respond_to?(:to_h)

    value.to_h.deep_symbolize_keys
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
end
