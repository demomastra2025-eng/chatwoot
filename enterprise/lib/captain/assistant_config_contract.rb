# frozen_string_literal: true

# Agent configuration is not a second copy of workspace settings or platform model settings.
# Old values stay in storage for rollback, but are neither writable nor advertised as effective.
module Captain::AssistantConfigContract
  class Violation < ArgumentError
    attr_reader :code, :fields

    def initialize(code, fields)
      @code = code
      @fields = fields
      super(code)
    end
  end

  PLATFORM_FIELDS = %w[model temperature thinking_effort].freeze
  WORKSPACE_FIELDS = %w[
    feature_faq feature_memory feature_citation feature_web feature_document_reading feature_image_understanding
    use_audio_transcriptions handoff_enabled auto_completion_enabled auto_reply_on_last_incoming
    handoff_message handoff_message_enabled handoff_message_mode resolution_message resolution_message_enabled
    resolution_message_mode message_collapse_window_seconds history_message_limit safety_settings welcome_message
  ].freeze
  UNSUPPORTED_FIELDS = (PLATFORM_FIELDS + WORKSPACE_FIELDS).freeze
  PRIVATE_FIELDS = %w[
    handoff_requires_explicit_consent handoff_consent_reason rules skills main_prompt_rules_migration legacy_scenario_migration capabilities_migration
  ].freeze
  VOICE_PROMPT_FIELDS = %w[system_prompt voice_character_prompt].freeze

  def self.unsupported_fields(config)
    return [] unless config.respond_to?(:keys)

    config.keys.map(&:to_s) & (UNSUPPORTED_FIELDS + PRIVATE_FIELDS)
  end

  def self.voice_prompt_fields(config)
    return [] unless config.respond_to?(:[])

    voice = config[:voice_settings] || config['voice_settings']
    return [] unless voice.respond_to?(:keys)

    (voice.keys.map(&:to_s) & VOICE_PROMPT_FIELDS).map { |field| "config.voice_settings.#{field}" }
  end

  def self.platform_capability_fields(config)
    return [] unless config.respond_to?(:keys)

    (config.keys.map(&:to_s) & %w[tool_access capabilities]).map { |field| "config.#{field}" }
  end

  def self.write_violation(attributes, platform:)
    return unless attributes.respond_to?(:key?)

    restricted = platform_violation(attributes) unless platform
    return restricted if restricted

    fields = unsupported_fields(attributes[:config]).map { |field| "config.#{field}" }
    { error: 'unsupported_assistant_settings', fields: fields } if fields.any?
  end

  def self.platform_violation(attributes)
    fields = voice_prompt_fields(attributes[:config])
    fields.unshift('description') if attributes.key?(:description)
    return { error: 'platform_managed_prompt', fields: fields } if fields.any?

    fields = platform_capability_fields(attributes[:config])
    { error: 'platform_managed_capabilities', fields: fields } if fields.any?
  end

  def self.public_config(assistant, prompt_access: false)
    config = assistant.config.to_h.except(*(UNSUPPORTED_FIELDS + PRIVATE_FIELDS))
    config.delete('tool_access') if Captain::Capabilities.configured?(assistant.config)
    config['voice_settings'] = config['voice_settings'].except(*VOICE_PROMPT_FIELDS) if !prompt_access && config['voice_settings'].is_a?(Hash)
    config
  end

  def self.effective_settings(assistant)
    settings = {
      feature_memory: assistant.feature_memory,
      history_message_limit: assistant.history_message_limit_value,
      message_collapse_window_seconds: assistant.message_collapse_window_seconds_value
    }
    settings[:model] = assistant.resolved_agent_model unless assistant.internal_assistant?
    settings
  end
end
