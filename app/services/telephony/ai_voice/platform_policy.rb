# frozen_string_literal: true

# One installation-owned native-audio profile. Stored assistant/route settings
# contribute business preferences and private instructions, never model selection.
class Telephony::AiVoice::PlatformPolicy
  DEFAULTS = Telephony::AiVoice::VoiceSettingsDefaults
  RETIRED_FIELDS = %w[humanlike_defaults_profile provider stt_provider model delegation_model thinking_level api_version temperature max_output_tokens
                      context_window_compression_enabled proactive_audio_enabled affective_dialog_enabled].freeze
  PROMPT_FIELDS = %w[system_prompt voice_character_prompt].freeze
  VOICES = %w[sulafat aoede charon fenrir kore puck].freeze
  VOICE_OPTIONS = VOICES.map { |voice| { value: voice, label: voice.capitalize }.freeze }.freeze

  def self.schema(prompt_access: true)
    fields = DEFAULTS::DEFAULTS.transform_values { |value| value.is_a?(Array) ? [:scalar] : :scalar }
    prompt_access ? fields : fields.except(*PROMPT_FIELDS)
  end

  def self.write_violation(settings, platform:, path: 'voice_settings')
    return { error: 'unsupported_voice_settings', fields: [path] } unless settings.respond_to?(:keys)

    violation = restricted_write_violation(settings, platform: platform, path: path)
    return violation if violation

    fields = PublicJsonFields.unknown_fields(settings, schema, path)
    return { error: 'unsupported_voice_settings', fields: fields } if fields.any?

    voice_violation(settings, path: path)
  end

  def self.voice_violation(settings, path:)
    return unless settings.key?(:voice) || settings.key?('voice')

    voice = settings.key?(:voice) ? settings[:voice] : settings['voice']
    return if VOICES.include?(normalized_voice(voice))

    { error: 'unsupported_voice', fields: ["#{path}.voice"] }
  end

  def self.normalized_voice(value)
    DEFAULTS.normalize('voice' => value).fetch('voice').to_s.downcase
  end

  def self.restricted_write_violation(settings, platform:, path:)
    fields = field_paths(settings, RETIRED_FIELDS, path)
    return { error: 'platform_managed_voice_policy', fields: fields } if fields.any?
    return if platform

    fields = field_paths(settings, PROMPT_FIELDS, path)
    { error: 'platform_managed_prompt', fields: fields } if fields.any?
  end

  def self.field_paths(settings, keys, path)
    (settings.keys.map(&:to_s) & keys).map { |field| "#{path}.#{field}" }
  end

  def self.validate_write!(settings, platform:, path: 'ai_voice_settings')
    violation = write_violation(settings, platform: platform, path: path)
    return unless violation

    raise Telephony::Error.new(code: violation[:error], message: violation[:error], details: { fields: violation[:fields] })
  end

  # Normalize only submitted fields. Retained legacy settings are provenance and
  # must neither block an unrelated edit nor be silently rewritten on save.
  def self.merge_updates(existing, incoming)
    incoming = incoming.to_h.deep_stringify_keys
    normalized = DEFAULTS.normalize(incoming).slice(*incoming.keys)
    retained = existing.is_a?(Hash) ? existing.deep_stringify_keys : {}
    retained.merge(normalized)
  end

  def self.prompt_access?(user:, impersonation: nil)
    defined?(Captain::PromptInspectorAccess) && Captain::PromptInspectorAccess.allowed?(user: user, impersonation: impersonation)
  end

  def initialize(account:, settings: {})
    @account = account
    @settings = settings.is_a?(Hash) ? settings.deep_stringify_keys : {}
  end

  def resolve
    @resolve ||= begin
      business = PublicJsonFields.project(@settings, self.class.schema).except(*RETIRED_FIELDS)
      normalized = DEFAULTS.normalize(business.merge(DEFAULTS::DEFAULTS.slice(*RETIRED_FIELDS)))
      normalized['voice'] = compatible_voice(business['voice'])
      normalized['delegation_model'] = Llm::Config.model_for(feature: :assistant, account: @account)
      normalized
    end
  end

  def public_settings(user: nil, impersonation: nil)
    PublicJsonFields.project(resolve, self.class.schema(prompt_access: self.class.prompt_access?(user: user, impersonation: impersonation)))
  end

  # Reading metadata never requires an available model. Actual runtime context
  # creation fails explicitly instead of restoring a saved account/agent fallback.
  def validate_runtime!
    return if resolve['delegation_model'].present?

    raise Telephony::Error.new(
      code: 'voice_delegation_unavailable', message: 'The platform assistant function is unavailable.', status: :service_unavailable
    )
  end

  private

  def compatible_voice(value)
    voice = self.class.normalized_voice(value)
    VOICES.include?(voice) ? voice : DEFAULTS::DEFAULTS.fetch('voice')
  end
end
