# frozen_string_literal: true

class Llm::ModelRegistryService
  LAST_REFRESH_AT_CACHE_KEY = 'llm/model_registry/last_refresh_at'
  LAST_REFRESH_ERROR_CACHE_KEY = 'llm/model_registry/last_refresh_error'

  class InvalidConfigurationError < StandardError; end

  class << self
    def runtime_metadata(account:)
      {
        defaults: defaults_metadata,
        registry: registry_metadata,
        providers: provider_metadata,
        features: feature_metadata(account),
        audit: audit_configuration
      }
    end

    def refresh!(remote_only: true)
      RubyLLM.models.refresh!(remote_only: remote_only)
      @last_refreshed_at = Time.current.iso8601
      @last_refresh_error = nil
      Rails.cache.write(LAST_REFRESH_AT_CACHE_KEY, @last_refreshed_at)
      Rails.cache.delete(LAST_REFRESH_ERROR_CACHE_KEY)

      registry_metadata.merge(remote_only: remote_only)
    rescue StandardError => e
      @last_refresh_error = "#{e.class}: #{e.message}"
      Rails.cache.write(LAST_REFRESH_ERROR_CACHE_KEY, @last_refresh_error)
      raise
    end

    def audit_configuration
      errors = []
      warnings = []

      validate_configured_models(errors:, warnings:)
      validate_feature_defaults(errors:)
      validate_installation_defaults(errors:)
      validate_moderation_model(errors:)

      {
        valid: errors.empty?,
        errors: errors,
        warnings: warnings
      }
    end

    def audit_configuration!
      result = audit_configuration
      return result if result[:valid]

      raise InvalidConfigurationError, result[:errors].join("\n")
    end

    private

    def defaults_metadata
      {
        installation_default_model: Llm::Config.installation_default_model,
        moderation_model: Llm::Config.moderation_model
      }
    end

    def registry_metadata
      runtime_models = Array(RubyLLM.models.all)

      {
        total_models: runtime_models.count,
        chat_models: runtime_models.count { |model| model.type == 'chat' },
        configured_models: Llm::Models.models.count,
        resolved_models: Llm::Models.models.keys.count { |model_name| Llm::Models.registry_known?(model_name) },
        last_refreshed_at: Rails.cache.read(LAST_REFRESH_AT_CACHE_KEY) || @last_refreshed_at,
        last_refresh_error: Rails.cache.read(LAST_REFRESH_ERROR_CACHE_KEY) || @last_refresh_error
      }
    end

    def provider_metadata
      Llm::Models.providers.each_with_object({}) do |(provider_name, config), result|
        result[provider_name] = {
          display_name: config['display_name'],
          configured: Llm::Config.provider_available?(provider_name),
          custom_endpoint: Llm::Config.custom_api_base_configured?(provider_name)
        }
      end
    end

    def feature_metadata(account)
      Llm::Models.feature_keys.each_with_object({}) do |feature_key, result|
        selected_model = Llm::Config.model_for(feature: feature_key, account: account)
        provider = Llm::Config.provider_for_model(selected_model)

        result[feature_key] = {
          selected_model: selected_model,
          provider: provider,
          provider_display_name: Llm::Models.provider_config(provider)&.fetch('display_name', provider.to_s.titleize),
          provider_configured: Llm::Config.provider_available?(provider),
          custom_endpoint: Llm::Config.custom_api_base_configured?(provider),
          type: Llm::Models.type_for(selected_model),
          capabilities: Llm::Models.capabilities_for(selected_model),
          supports_thinking: Llm::Models.supports_thinking?(selected_model),
          known_to_registry: Llm::Models.registry_known?(selected_model)
        }
      end
    end

    def validate_configured_models(errors:, warnings:)
      Llm::Models.models.each do |model_name, model_config|
        provider_name = model_config.fetch('provider', nil)

        errors << "Model '#{model_name}' references unknown provider '#{provider_name}'." if provider_name.present? &&
          !Llm::Models.providers.key?(provider_name)

        unless Llm::Models.registry_known?(model_name)
          errors << "Configured model '#{model_name}' is not known to RubyLLM.models."
          next
        end

        validate_registry_type(model_name, model_config, errors)
        validate_registry_capabilities(model_name, warnings)
      end
    end

    def validate_registry_type(model_name, model_config, errors)
      configured_type = model_config['type'].presence
      registry_type = Llm::Models.registry_model_for(model_name)&.type.to_s.presence
      return if configured_type.blank? || registry_type.blank? || configured_type == registry_type

      errors << "Configured model '#{model_name}' declares type '#{configured_type}' but RubyLLM registry reports '#{registry_type}'."
    end

    def validate_registry_capabilities(model_name, warnings)
      configured_capabilities = Array(Llm::Models.model_config(model_name)&.fetch('capabilities', nil)).map(&:to_s).sort
      registry_capabilities = Array(Llm::Models.registry_model_for(model_name)&.capabilities).map(&:to_s).sort
      return if configured_capabilities.blank? || registry_capabilities.blank?
      return if configured_capabilities == registry_capabilities

      warnings << "Configured model '#{model_name}' capabilities #{configured_capabilities.inspect} differ from RubyLLM registry #{registry_capabilities.inspect}."
    end

    def validate_feature_defaults(errors:)
      Llm::Models.feature_keys.each do |feature_key|
        feature_config = Llm::Models.features[feature_key]
        next if feature_config.blank?

        default_model = feature_config['default']
        allowed_models = Array(feature_config['models'])

        if default_model.blank?
          errors << "Feature '#{feature_key}' is missing a default model."
          next
        end

        errors << "Feature '#{feature_key}' default '#{default_model}' is not listed in its allowed models." unless allowed_models.include?(default_model)
        errors << "Feature '#{feature_key}' default '#{default_model}' is not defined in config/llm.yml models." unless Llm::Models.models.key?(default_model)
        errors << "Feature '#{feature_key}' default '#{default_model}' is not known to RubyLLM.models." unless Llm::Models.registry_known?(default_model)
      end
    end

    def validate_installation_defaults(errors:)
      installation_default_model = Llm::Config.installation_default_model
      return if installation_default_model.blank?

      unless Llm::Models.models.key?(installation_default_model)
        errors << "Installation default model '#{installation_default_model}' is not defined in config/llm.yml."
        return
      end

      errors << "Installation default model '#{installation_default_model}' is not known to RubyLLM.models." unless Llm::Models.registry_known?(installation_default_model)
    end

    def validate_moderation_model(errors:)
      moderation_model = Llm::Config.moderation_model
      return if moderation_model.blank?

      errors << "Moderation model '#{moderation_model}' is not known to RubyLLM.models." unless Llm::Models.registry_known?(moderation_model)
    end
  end
end
