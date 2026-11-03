require 'ruby_llm'

# rubocop:disable Metrics/ModuleLength
module Llm::Config
  DEFAULT_MODEL = 'openai/gpt-6-luna'.freeze
  DEFAULT_TRANSCRIPTION_MODEL = 'openai/gpt-4o-mini-transcribe'.freeze
  DEFAULT_MODERATION_MODEL = nil
  DEFAULT_OPENROUTER_MODERATION_MODEL_FEATURE = 'moderation'.freeze
  # Models of these features are chosen by the platform (Super Admin -> AI Agents), never by an account: the
  # recognition models (voice, images, guardrail), the knowledge embedding and the AI hints (label suggestions).
  INSTALLATION_MANAGED_MODEL_CONFIGS = {
    'audio_transcription' => 'CAPTAIN_AUDIO_TRANSCRIPTION_MODEL',
    'image_recognition' => 'CAPTAIN_IMAGE_RECOGNITION_MODEL',
    'image_handwriting' => 'CAPTAIN_IMAGE_HANDWRITING_MODEL',
    'image_routing' => 'CAPTAIN_IMAGE_ROUTER_MODEL',
    'help_center_search' => 'CAPTAIN_EMBEDDING_MODEL',
    'moderation' => 'CAPTAIN_MODERATION_MODEL',
    'custom_guardrail' => 'CAPTAIN_CUSTOM_GUARDRAIL_MODEL',
    'customer_notice' => 'CAPTAIN_CUSTOMER_NOTICE_MODEL',
    'label_suggestion' => 'CAPTAIN_LABEL_SUGGESTION_MODEL',
    'outcome_classification' => 'CAPTAIN_OUTCOME_CLASSIFIER_MODEL',
    'language_detection' => 'CAPTAIN_LANGUAGE_DETECTION_MODEL',
    'agent_routing_escalation' => 'CAPTAIN_AGENT_ROUTING_ESCALATION_MODEL',
    'council_split' => 'CAPTAIN_COUNCIL_SPLIT_MODEL',
    'council_edit' => 'CAPTAIN_COUNCIL_EDITOR_MODEL'
  }.freeze
  INSTALLATION_DEFAULT_MODEL_FEATURES = %w[assistant editor copilot].freeze
  INSTALLATION_MANAGED_MODEL_FEATURES = (
    INSTALLATION_MANAGED_MODEL_CONFIGS.keys + INSTALLATION_DEFAULT_MODEL_FEATURES +
    %w[agent_routing fact_check_gate inbound_triage knowledge_rerank]
  ).freeze
  # Image readers and council transforms have their own defaults (config/llm.yml): a blank slot never follows CAPTAIN_DEFAULT_MODEL,
  # so moving the main agent does not move image reading, message splitting or reply editing with it.
  OWN_DEFAULT_MODEL_FEATURES = %w[image_recognition image_handwriting council_split council_edit].freeze
  OPENAI_DEFAULT_API_BASE = 'https://api.openai.com/v1'.freeze
  OPENROUTER_DEFAULT_API_BASE = 'https://openrouter.ai/api/v1'.freeze
  THINKING_EFFORT_CONFIGS = {
    'assistant' => 'CAPTAIN_AI_AGENT_THINKING_EFFORT', 'copilot' => 'CAPTAIN_AI_ASSISTANT_THINKING_EFFORT'
  }.freeze
  THINKING_EFFORT_DEFAULTS = { 'assistant' => 'low', 'copilot' => 'none' }.freeze
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
      return yield if Thread.current[RUNTIME_CACHE_KEY].present?

      begin
        Thread.current[RUNTIME_CACHE_KEY] = {
          installation_configs: {},
          account_provider_hooks: {}
        }

        yield
      ensure
        Thread.current[RUNTIME_CACHE_KEY] = nil
      end
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
      return moderation_model(account: account) if feature.to_s == 'moderation'

      feature_model_for(feature: feature, account: account, fallback: fallback)
    end

    def feature_model_for(feature: nil, account: nil, fallback: DEFAULT_MODEL)
      feature_key = feature.to_s.presence

      explicit_model = explicit_model_for(feature_key, account: account)
      return explicit_model if explicit_model.present?

      installation_model = installation_model_for(feature_key, account: account) unless follows_no_installation_default?(feature_key)
      return installation_model if installation_model.present?

      if feature_key.present?
        feature_default_model = Llm::Models.default_model_for(feature_key, account: account)
        return feature_default_model if default_model_available?(feature_default_model, account: account)
        return if Llm::Models.openrouter_no_fallback_active_for?(feature_key, account: account)
      end

      default_model_available?(fallback, account: account) ? Llm::Models.canonical_model_name(fallback) : nil
    end

    private :feature_model_for

    # Function slots belong to the installation. Saved account/agent efforts are
    # retained in storage only and never participate in runtime selection.
    def thinking_effort_for(feature:, fallback: nil)
      key = feature.to_s
      slot = THINKING_EFFORT_CONFIGS[key]
      effort = installation_config_value(slot).to_s if slot
      return effort if Llm::RuntimePolicy::THINKING_EFFORTS.include?(effort)

      fallback || THINKING_EFFORT_DEFAULTS.fetch(key, 'none')
    end

    def runtime_thinking_efforts
      THINKING_EFFORT_CONFIGS.keys.each_with_object({}) do |feature, values|
        values["#{feature}_thinking_effort"] = thinking_effort_for(feature: feature)
      end
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
      model = Llm::Models.canonical_model_name(installation_config_value('CAPTAIN_MODERATION_MODEL').to_s.strip)
      return if model.blank? || Llm::Models.retired_model?(model)
      return unless provider_for_model(model, account: account) == 'openrouter'

      diagnostics = Llm::Models.capability_diagnostics_for(:moderation, model, account: account)
      return if diagnostics.model_config.blank?
      return unless diagnostics.reasons.all? { |reason| reason[:code] == 'provider_not_configured' }

      model
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

    # An account may bring its own OpenRouter key only when the platform enabled the flag for it. The legacy direct
    # providers are not offered in the settings (only OpenRouter is visible), so nothing new can be stored for them.
    def account_provider_byok_allowed?(provider, account: nil)
      return false if account.blank?
      return true unless provider.to_s == 'openrouter'

      account.respond_to?(:feature_enabled?) && account.feature_enabled?('captain_openrouter_byok')
    end

    def installation_managed_model_feature?(feature_key)
      INSTALLATION_MANAGED_MODEL_FEATURES.include?(feature_key.to_s)
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
      return unless account_provider_byok_allowed?(provider, account: account)

      hook = account_provider_hook(account, provider)
      settings = hook&.settings.to_h.with_indifferent_access

      hook&.access_token.presence || settings&.dig(:api_key).presence
    end

    def account_api_base(provider, account)
      return unless account_provider_byok_allowed?(provider, account: account)

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

    # Every model is selected by its platform feature slot or the platform default.
    def explicit_model_for(feature_key, account: nil)
      return unless INSTALLATION_MANAGED_MODEL_CONFIGS.key?(feature_key)

      installation_managed_model_for(feature_key, account: account)
    end

    def installation_managed_model_for(feature_key, account: nil)
      model_name = installation_config_value(INSTALLATION_MANAGED_MODEL_CONFIGS[feature_key.to_s]).presence
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

    # A decision feature picks among decision models; image readers and council transforms have their own defaults. None follows the
    # installation default model.
    def follows_no_installation_default?(feature_key)
      Llm::FeatureProfile.decision_feature?(feature_key) || OWN_DEFAULT_MODEL_FEATURES.include?(feature_key.to_s)
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
