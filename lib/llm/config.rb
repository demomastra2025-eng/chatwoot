require 'ruby_llm'

# rubocop:disable Metrics/ModuleLength
module Llm::Config
  DEFAULT_MODEL = 'gpt-5.4-mini'.freeze
  DEFAULT_TRANSCRIPTION_MODEL = 'gpt-4o-transcribe'.freeze
  DEFAULT_MODERATION_MODEL = 'omni-moderation-latest'.freeze
  OPENAI_DEFAULT_API_BASE = 'https://api.openai.com/v1'.freeze

  class << self
    def initialized?
      @initialized ||= false
    end

    def initialize!
      return if @initialized

      configure_ruby_llm
      @initialized = true
    end

    def reset!
      @initialized = false
    end

    def context(api_key: nil, api_base: nil, provider: nil, model: nil, overrides: nil)
      provider_overrides = normalized_provider_overrides(
        provider: provider,
        model: model,
        api_key: api_key,
        api_base: api_base,
        overrides: overrides
      )
      return nil if provider_overrides.blank?

      Llm::ApiClient.context do |config|
        apply_provider_overrides(config, provider_overrides)
      end
    end

    def with_api_key(api_key, api_base: nil, provider: nil, model: nil)
      yield context(api_key: api_key, api_base: api_base, provider: provider, model: model)
    end

    def model_for(feature: nil, account: nil, fallback: DEFAULT_MODEL)
      feature_key = feature.to_s.presence

      account_model = account_model_for(account, feature_key)
      return account_model if account_model.present?

      installation_model = installation_model_for(feature_key)
      return installation_model if installation_model.present?

      if feature_key.present?
        feature_default_model = Llm::Models.default_model_for(feature_key)
        return feature_default_model if runtime_usable_model?(feature_default_model)
      end

      fallback
    end

    def provider_for_model(model_name)
      Llm::Models.provider_for(Llm::Models.canonical_model_name(model_name)) || 'openai'
    end

    def api_key(provider = 'openai')
      config_name = provider_config(provider)&.fetch('api_key_config', nil)
      return if config_name.blank?

      InstallationConfig.find_by(name: config_name)&.value.presence
    end

    def api_base(provider = 'openai')
      endpoint = provider_endpoint(provider)
      return default_api_base(provider) if endpoint.blank?

      normalize_api_base(endpoint, provider: provider)
    end

    def moderation_model
      InstallationConfig.find_by(name: 'CAPTAIN_MODERATION_MODEL')&.value.presence || DEFAULT_MODERATION_MODEL
    end

    def moderation_provider
      provider_for_model(moderation_model)
    end

    def global_agent_system_prompt
      installation_text_config('CAPTAIN_AI_AGENT_SYSTEM_PROMPT')
    end

    def global_assistant_system_prompt
      installation_text_config('CAPTAIN_AI_ASSISTANT_SYSTEM_PROMPT')
    end

    def installation_default_model
      InstallationConfig.find_by(name: 'CAPTAIN_DEFAULT_MODEL')&.value.presence ||
        InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence
    end

    def provider_available?(provider)
      api_key(provider).present?
    end

    def custom_api_base_configured?(provider)
      provider_endpoint(provider).present?
    end

    private

    def configure_ruby_llm
      Llm::ApiClient.configure do |config|
        config.model_registry_file = Rails.root.join('config/llm_models.json').to_s if config.respond_to?(:model_registry_file=)
        config.logger = Rails.logger
        config.default_moderation_model = moderation_model
        apply_provider_overrides(config, default_provider_overrides)
      end
    end

    def default_provider_overrides
      Llm::Models.providers.keys.each_with_object({}) do |provider_name, result|
        api_key = api_key(provider_name)
        api_base = api_base(provider_name)
        next if api_key.blank? && api_base.blank?

        result[provider_name] = {
          api_key: api_key,
          api_base: api_base
        }
      end
    end

    def provider_config(provider_name)
      Llm::Models.provider_config(provider_name)
    end

    def provider_endpoint(provider_name)
      config_name = provider_config(provider_name)&.fetch('api_base_config', nil)
      return if config_name.blank?

      InstallationConfig.find_by(name: config_name)&.value.presence
    end

    def default_api_base(provider_name)
      return OPENAI_DEFAULT_API_BASE if provider_name.to_s == 'openai'

      nil
    end

    def normalize_api_base(value, provider: 'openai')
      base = value.to_s.chomp('/')
      return default_api_base(provider) if base.blank?

      return base unless provider.to_s == 'openai'

      base.end_with?('/v1') ? base : "#{base}/v1"
    end

    def normalized_provider_overrides(provider: nil, model: nil, api_key: nil, api_base: nil, overrides: nil)
      return normalize_overrides_hash(overrides) if overrides.present?

      resolved_provider = provider.presence || provider_for_model(model)
      return {} if resolved_provider.blank?

      {
        resolved_provider => {
          api_key: api_key.presence,
          api_base: api_base.present? ? normalize_api_base(api_base, provider: resolved_provider) : nil
        }.compact
      }
    end

    def normalize_overrides_hash(overrides)
      overrides.each_with_object({}) do |(provider_name, values), result|
        provider_name = provider_name.to_s
        next if values.blank?

        api_key = values[:api_key] || values['api_key']
        api_base = values[:api_base] || values['api_base']
        result[provider_name] = {
          api_key: api_key.presence,
          api_base: api_base.present? ? normalize_api_base(api_base, provider: provider_name) : nil
        }.compact
      end
    end

    def apply_provider_overrides(config, provider_overrides)
      provider_overrides.each do |provider_name, values|
        apply_provider_override(config, provider_name, values)
      end
    end

    def apply_provider_override(config, provider_name, values)
      api_key = values[:api_key] || values['api_key']
      api_base = values[:api_base] || values['api_base']

      api_key_writer = "#{provider_name}_api_key="
      api_base_writer = "#{provider_name}_api_base="

      config.public_send(api_key_writer, api_key) if api_key.present? && config.respond_to?(api_key_writer)
      config.public_send(api_base_writer, api_base) if api_base.present? && config.respond_to?(api_base_writer)
    end

    def account_model_for(account, feature_key)
      return if account.blank? || feature_key.blank?

      accessor_name = "captain_#{feature_key}_model"
      return unless account.respond_to?(accessor_name)

      model_name = account.public_send(accessor_name)
      return unless model_name.present?
      return unless Llm::Models.valid_model_for?(feature_key, model_name)

      canonical_model = Llm::Models.canonical_model_name(model_name)
      return unless runtime_usable_model?(canonical_model)

      canonical_model
    end

    def installation_model_for(feature_key)
      model_name = installation_default_model
      return if model_name.blank?

      canonical_model = Llm::Models.canonical_model_name(model_name)
      return canonical_model if feature_key.blank? && runtime_usable_model?(canonical_model)
      return if feature_key.blank?
      return unless Llm::Models.valid_model_for?(feature_key, model_name)
      return unless runtime_usable_model?(canonical_model)

      canonical_model
    end

    def installation_text_config(name)
      InstallationConfig.find_by(name: name)&.value.to_s.strip.presence
    end

    def runtime_usable_model?(model_name)
      canonical_model = Llm::Models.canonical_model_name(model_name)
      canonical_model.present? && Llm::Models.runtime_supported?(canonical_model)
    end
  end
end
# rubocop:enable Metrics/ModuleLength
