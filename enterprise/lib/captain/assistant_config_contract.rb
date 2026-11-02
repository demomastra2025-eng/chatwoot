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

  VOICE_PROMPT_FIELDS = Telephony::AiVoice::PlatformPolicy::PROMPT_FIELDS

  def self.voice_prompt_fields(config)
    return [] unless config.respond_to?(:[])

    voice = config[:voice_settings] || config['voice_settings']
    return [] unless voice.respond_to?(:keys)

    (voice.keys.map(&:to_s) & VOICE_PROMPT_FIELDS).map { |field| "config.voice_settings.#{field}" }
  end

  def self.follow_up_prompt_fields(config)
    return [] unless config.respond_to?(:[])

    settings = config[:follow_up_settings] || config['follow_up_settings']
    settings.respond_to?(:keys) && settings.keys.map(&:to_s).include?('prompt') ? ['config.follow_up_settings.prompt'] : []
  end

  def self.platform_capability_fields(config)
    return [] unless config.respond_to?(:keys)

    (config.keys.map(&:to_s) & %w[tool_access capabilities]).map { |field| "config.#{field}" }
  end

  def self.write_violation(attributes, platform:)
    return unless attributes.respond_to?(:key?)

    attributes = normalized_attributes(attributes)
    return unsupported_settings(['config']) if malformed_config?(attributes)

    restricted = platform_violation(attributes) unless platform
    restricted ||= voice_violation(attributes[:config], platform: platform)
    return restricted if restricted

    fields = Captain::AssistantSerializer.unknown_fields(attributes[:config])
    unsupported_settings(fields) if fields.any?
  end

  def self.normalized_attributes(attributes)
    attributes.is_a?(Hash) ? attributes.with_indifferent_access : attributes
  end

  def self.malformed_config?(attributes)
    attributes.key?(:config) && !attributes[:config].respond_to?(:keys)
  end

  def self.voice_violation(config, platform:)
    return unless config.respond_to?(:key?) && config.key?(:voice_settings)

    violation = Telephony::AiVoice::PlatformPolicy.write_violation(config[:voice_settings], platform: platform, path: 'config.voice_settings')
    return unless violation

    violation[:error] == 'unsupported_voice_settings' ? unsupported_settings(violation[:fields]) : violation
  end

  def self.unsupported_settings(fields)
    { error: 'unsupported_assistant_settings', fields: fields }
  end

  def self.platform_violation(attributes)
    fields = voice_prompt_fields(attributes[:config]) + follow_up_prompt_fields(attributes[:config])
    fields.unshift('description') if attributes.key?(:description)
    return { error: 'platform_managed_prompt', fields: fields } if fields.any?

    fields = platform_capability_fields(attributes[:config])
    { error: 'platform_managed_capabilities', fields: fields } if fields.any?
  end

  def self.effective_settings(assistant)
    settings = {
      voice_options: Telephony::AiVoice::PlatformPolicy::VOICE_OPTIONS,
      feature_memory: assistant.feature_memory,
      history_message_limit: assistant.history_message_limit_value,
      message_collapse_window_seconds: assistant.message_collapse_window_seconds_value
    }
    settings[:model] = assistant.resolved_agent_model unless assistant.internal_assistant?
    settings
  end
end
