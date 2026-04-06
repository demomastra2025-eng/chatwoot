module Llm::Models
  CONFIG = YAML.load_file(Rails.root.join('config/llm.yml')).freeze

  class << self
    def providers = CONFIG['providers']
    def models = CONFIG['models']
    def features = CONFIG['features']
    def feature_keys = CONFIG['features'].keys

    def default_model_for(feature)
      CONFIG.dig('features', feature.to_s, 'default')
    end

    def models_for(feature)
      CONFIG.dig('features', feature.to_s, 'models') || []
    end

    def valid_model_for?(feature, model_name)
      models_for(feature).include?(model_name.to_s)
    end

    def model_config(model_name)
      models[model_name.to_s]
    end

    def provider_for(model_name)
      model_config(model_name)&.fetch('provider', nil)
    end

    def provider_config(provider_name)
      providers&.fetch(provider_name.to_s, nil)
    end

    def type_for(model_name)
      model_config(model_name)&.fetch('type', nil) || registry_info_for(model_name)&.type
    end

    def capabilities_for(model_name)
      Array(model_config(model_name)&.fetch('capabilities', nil)).map(&:to_s) |
        Array(registry_info_for(model_name)&.capabilities).map(&:to_s)
    end

    def supports?(model_name, capability)
      capabilities_for(model_name).include?(capability.to_s)
    end

    def supports_thinking?(model_name)
      supports?(model_name, :reasoning)
    end

    def registry_model_for(model_name)
      RubyLLM.models.find(model_name)
    rescue StandardError
      nil
    end

    def registry_known?(model_name)
      registry_model_for(model_name).present?
    end

    def feature_config(feature_key)
      feature = features[feature_key.to_s]
      return nil unless feature

      {
        models: feature['models'].map do |model_name|
          model = model_config(model_name)
          {
            id: model_name,
            display_name: model['display_name'],
            provider: model['provider'],
            coming_soon: model['coming_soon'],
            credit_multiplier: model['credit_multiplier'],
            capabilities: capabilities_for(model_name),
            type: type_for(model_name),
            known_to_registry: registry_known?(model_name)
          }
        end,
        default: feature['default']
      }
    end

    private

    def registry_info_for(model_name)
      return @registry_info[model_name] if defined?(@registry_info) && @registry_info.key?(model_name)

      @registry_info ||= {}
      @registry_info[model_name] =
        RubyLLM.models.find(model_name)
    rescue StandardError
      @registry_info[model_name] = nil
    end
  end
end
