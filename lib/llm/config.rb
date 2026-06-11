require 'ruby_llm'

# rubocop:disable Metrics/ModuleLength
module Llm::Config
  DEFAULT_MODEL = 'openai/gpt-5.4-mini'.freeze
  DEFAULT_TRANSCRIPTION_MODEL = 'openai/gpt-4o-mini-transcribe'.freeze
  DEFAULT_MODERATION_MODEL = 'openai/gpt-oss-safeguard-20b'.freeze
  DEFAULT_OPENROUTER_MODERATION_MODEL_FEATURE = 'moderation'.freeze
  OPENAI_DEFAULT_API_BASE = 'https://api.openai.com/v1'.freeze
  OPENROUTER_DEFAULT_API_BASE = 'https://openrouter.ai/api/v1'.freeze
  RUNTIME_CACHE_KEY = :llm_config_runtime_cache

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

    def with_runtime_cache
      previous_cache = Thread.current[RUNTIME_CACHE_KEY]
      Thread.current[RUNTIME_CACHE_KEY] = {
        installation_configs: {},
        account_provider_hooks: {}
      }

      yield
    ensure
      Thread.current[RUNTIME_CACHE_KEY] = previous_cache
    end

    def context(api_key: nil, api_base: nil, provider: nil, model: nil, overrides: nil, account: nil)
      provider_overrides = normalized_provider_overrides(
        provider: provider,
        model: model,
        api_key: api_key,
        api_base: api_base,
        overrides: overrides,
        account: account
      )
      return nil if provider_overrides.blank?

      Llm::ApiClient.context do |config|
        apply_provider_overrides(config, provider_overrides)
      end
    end

    def with_api_key(api_key, api_base: nil, provider: nil, model: nil, account: nil)
      yield context(api_key: api_key, api_base: api_base, provider: provider, model: model, account: account)
    end

    def model_for(feature: nil, account: nil, fallback: DEFAULT_MODEL)
      feature_key = feature.to_s.presence

      account_model = account_model_for(account, feature_key)
      return account_model if account_model.present?

      installation_model = installation_model_for(feature_key, account: account)
      return installation_model if installation_model.present?

      if feature_key.present?
        feature_default_model = Llm::Models.default_model_for(feature_key, account: account)
        return feature_default_model if default_model_available?(feature_default_model, account: account)
        return if Llm::Models.openrouter_no_fallback_active_for?(feature_key, account: account)
      end

      default_model_available?(fallback, account: account) ? Llm::Models.canonical_model_name(fallback) : nil
    end

    def provider_for_model(model_name, account: nil)
      canonical_model = Llm::Models.canonical_model_name(model_name)
      return if canonical_model.blank?

      Llm::Models.provider_for(canonical_model, account: account)
    end

    def api_key(provider = nil, account: nil)
      return if provider.blank?

      account_api_key(provider, account).presence || installation_api_key(provider)
    end

    def api_base(provider = nil, account: nil)
      return if provider.blank?

      endpoint = account_api_base(provider, account).presence || provider_endpoint(provider)
      return default_api_base(provider) if endpoint.blank?

      normalize_api_base(endpoint, provider: provider)
    end

    def moderation_model(account: nil)
      account_model = account_model_for(account, DEFAULT_OPENROUTER_MODERATION_MODEL_FEATURE)
      return account_model if account_model.present?

      configured_model = installation_config_value('CAPTAIN_MODERATION_MODEL').presence

      if openrouter_primary?(account: account)
        return configured_model if configured_model.present? && provider_for_model(configured_model, account: account) == 'openrouter'

        openrouter_model = Llm::Models.default_model_for(DEFAULT_OPENROUTER_MODERATION_MODEL_FEATURE, account: account)
        return openrouter_model if openrouter_model.present? && provider_for_model(openrouter_model, account: account) == 'openrouter'
      end

      configured_model.presence || DEFAULT_MODERATION_MODEL
    end

    def moderation_provider(account: nil)
      provider_for_model(moderation_model(account: account), account: account)
    end

    def openrouter_primary?(account: nil)
      provider_available?('openrouter', account: account)
    end

    def global_agent_system_prompt
      installation_text_config('CAPTAIN_AI_AGENT_SYSTEM_PROMPT')
    end

    def global_assistant_system_prompt
      installation_text_config('CAPTAIN_AI_ASSISTANT_SYSTEM_PROMPT')
    end

    def installation_default_model
      installation_config_value('CAPTAIN_DEFAULT_MODEL').presence ||
        installation_config_value('CAPTAIN_OPEN_AI_MODEL').presence
    end

    def provider_available?(provider, account: nil)
      api_key(provider, account: account).present?
    end

    def account_provider_available?(provider, account: nil)
      account_api_key(provider, account).present?
    end

    def installation_provider_available?(provider)
      installation_api_key(provider).present?
    end

    def custom_api_base_configured?(provider, account: nil)
      account_api_base(provider, account).present? || provider_endpoint(provider).present?
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

      installation_config_value(config_name).presence
    end

    def default_api_base(provider_name)
      case provider_name.to_s
      when 'openai'
        OPENAI_DEFAULT_API_BASE
      when 'openrouter'
        OPENROUTER_DEFAULT_API_BASE
      end
    end

    def normalize_api_base(value, provider: 'openai')
      base = value.to_s.chomp('/')
      return default_api_base(provider) if base.blank?

      return base unless provider.to_s == 'openai'

      base.end_with?('/v1') ? base : "#{base}/v1"
    end

    def normalized_provider_overrides(provider: nil, model: nil, api_key: nil, api_base: nil, overrides: nil, account: nil)
      return normalize_overrides_hash(overrides) if overrides.present?

      resolved_provider = provider.presence || provider_for_model(model, account: account)
      return {} if resolved_provider.blank?

      resolved_api_key = api_key.presence || self.api_key(resolved_provider, account: account)
      resolved_api_base = api_base.presence || self.api_base(resolved_provider, account: account)

      {
        resolved_provider => {
          api_key: resolved_api_key.presence,
          api_base: resolved_api_base.present? ? normalize_api_base(resolved_api_base, provider: resolved_provider) : nil
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

    def installation_api_key(provider)
      config_name = provider_config(provider)&.fetch('api_key_config', nil)
      return if config_name.blank?

      installation_config_value(config_name).presence
    end

    def account_api_key(provider, account)
      hook = account_provider_hook(account, provider)
      settings = hook&.settings.to_h.with_indifferent_access

      hook&.access_token.presence || settings&.dig(:api_key).presence
    end

    def account_api_base(provider, account)
      settings = account_provider_hook(account, provider)&.settings.to_h.with_indifferent_access
      settings[:api_base].presence || settings[:base_url].presence || settings[:endpoint].presence
    end

    def account_provider_hook(account, provider)
      return if account.blank? || provider.blank? || !account.respond_to?(:hooks)

      cache = runtime_cache
      return account.hooks.find_by(app_id: provider.to_s, status: 'enabled') if cache.blank? || account.id.blank?

      cache[:account_provider_hooks].fetch([account.id, provider.to_s]) do
        cache[:account_provider_hooks][[account.id, provider.to_s]] =
          account.hooks.find_by(app_id: provider.to_s, status: 'enabled')
      end
    end

    def account_model_for(account, feature_key)
      return if account.blank? || feature_key.blank?

      model_name = account.captain_models.to_h.with_indifferent_access[feature_key]
      return if model_name.blank?

      model_name = normal_feature_model_name(feature_key, model_name, account: account)
      return if model_name.blank?
      return unless feature_model_allowed?(feature_key, model_name, account: account)

      canonical_model = Llm::Models.canonical_model_name(model_name)
      return unless runtime_usable_model?(canonical_model, account: account)

      provider = provider_for_model(canonical_model, account: account)
      return unless provider_available?(provider, account: account)

      canonical_model
    end

    def installation_model_for(feature_key, account: nil)
      model_name = installation_default_model
      return if model_name.blank?

      model_name = normal_feature_model_name(feature_key, model_name, account: account) if feature_key.present?
      return if model_name.blank?

      canonical_model = Llm::Models.canonical_model_name(model_name)
      provider = provider_for_model(canonical_model, account: account)
      return unless provider_available?(provider, account: account)

      return canonical_model if feature_key.blank? && runtime_usable_model?(canonical_model, account: account)
      return if feature_key.blank?
      return unless feature_model_allowed?(feature_key, model_name, account: account)
      return unless runtime_usable_model?(canonical_model, account: account)

      canonical_model
    end

    def feature_model_allowed?(feature_key, model_name, account: nil)
      return true if Llm::Models.model_allowed_for_feature?(feature_key, model_name, account: account)
      return false if feature_key.to_s == 'help_center_search' && Llm::Models.openrouter_no_fallback_active_for?(feature_key, account: account)

      Llm::Models.configured_model_for_feature?(feature_key, model_name, account: account)
    end

    def normal_feature_model_name(feature_key, model_name, account: nil)
      migrated_model = Llm::OpenRouterModelMigration.resolve(model_name, feature: feature_key, account: account)
      return migrated_model if migrated_model.present?
      return if Llm::Models.openrouter_no_fallback_active_for?(feature_key, account: account)

      Llm::Models.canonical_model_name(model_name)
    end

    def installation_text_config(name)
      installation_config_value(name).to_s.strip.presence
    end

    def installation_config_value(name)
      cache = runtime_cache
      return InstallationConfig.find_by(name: name)&.value if cache.blank?

      cache[:installation_configs].fetch(name) do
        cache[:installation_configs][name] = InstallationConfig.find_by(name: name)&.value
      end
    end

    def runtime_cache
      Thread.current[RUNTIME_CACHE_KEY]
    end

    def runtime_usable_model?(model_name, account: nil)
      canonical_model = Llm::Models.canonical_model_name(model_name)
      canonical_model.present? && Llm::Models.runtime_supported?(canonical_model, account: account)
    end

    def default_model_available?(model_name, account: nil)
      canonical_model = Llm::Models.canonical_model_name(model_name)
      return false unless runtime_usable_model?(canonical_model, account: account)

      provider = provider_for_model(canonical_model, account: account)
      return false if provider.blank?

      provider_available?(provider, account: account)
    end
  end
end
# rubocop:enable Metrics/ModuleLength
