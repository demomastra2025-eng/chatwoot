module Llm::Models
  CONFIG = YAML.safe_load_file(Rails.root.join('config/llm.yml'), aliases: true).freeze
  LEGACY_MODEL_ALIASES = {
    'claude-haiku-4.5' => 'claude-haiku-4-5',
    'claude-sonnet-4.5' => 'claude-sonnet-4-5',
    'claude-sonnet-4.6' => 'claude-sonnet-4-6',
    'claude-opus-4.6' => 'claude-opus-4-6'
  }.freeze
  CAPABILITY_ALIASES = {
    'function_calling' => 'tool_calling',
    'vision' => 'multimodal_input'
  }.freeze
  TYPE_CAPABILITIES = {
    'embedding' => %w[embedding],
    'transcription' => %w[transcription]
  }.freeze

  class << self
    def providers = CONFIG['providers']
    def models = CONFIG['models']
    def features = CONFIG['features']
    def feature_keys = CONFIG['features'].keys

    def canonical_model_name(model_name)
      LEGACY_MODEL_ALIASES.fetch(model_name.to_s, model_name.to_s)
    end

    def default_model_for(feature)
      canonical_model_name(CONFIG.dig('features', feature.to_s, 'default'))
    end

    def models_for(feature)
      Array(CONFIG.dig('features', feature.to_s, 'models')).map { |model_name| canonical_model_name(model_name) }
    end

    def valid_model_for?(feature, model_name)
      models_for(feature).include?(canonical_model_name(model_name))
    end

    def model_config(model_name)
      models[canonical_model_name(model_name)]
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
      normalize_capabilities(
        Array(model_config(model_name)&.fetch('capabilities', nil)) +
        Array(registry_info_for(model_name)&.capabilities) +
        TYPE_CAPABILITIES.fetch(type_for(model_name).to_s, [])
      )
    end

    def supports?(model_name, capability)
      capabilities_for(model_name).include?(capability.to_s)
    end

    def supports_thinking?(model_name)
      supports?(model_name, :reasoning)
    end

    def supports_structured_output?(model_name)
      supports?(model_name, :structured_output)
    end

    def supports_tool_calling?(model_name)
      supports?(model_name, :tool_calling)
    end

    def supports_multimodal_input?(model_name)
      supports?(model_name, :multimodal_input)
    end

    def supports_streaming?(model_name)
      supports?(model_name, :streaming)
    end

    def supports_embedding?(model_name)
      supports?(model_name, :embedding)
    end

    def supports_transcription?(model_name)
      supports?(model_name, :transcription)
    end

    def registry_model_for(model_name)
      RubyLLM.models.find(canonical_model_name(model_name))
    rescue StandardError
      nil
    end

    def registry_known?(model_name)
      registry_model_for(model_name).present?
    end

    def runtime_supported?(model_name)
      registry_known?(model_name) || assume_exists_supported?(model_name)
    end

    def feature_config(feature_key)
      feature = features[feature_key.to_s]
      return nil unless feature

      {
        models: feature['models'].map do |model_name|
          canonical_name = canonical_model_name(model_name)
          model = model_config(canonical_name)
          {
            id: canonical_name,
            display_name: model['display_name'],
            provider: model['provider'],
            coming_soon: model['coming_soon'],
            credit_multiplier: model['credit_multiplier'],
            capabilities: capabilities_for(canonical_name),
            type: type_for(canonical_name),
            known_to_registry: registry_known?(canonical_name)
          }
        end,
        default: default_model_for(feature_key)
      }
    end

    def credit_multiplier_for(model_name)
      model_config(model_name)&.fetch('credit_multiplier', nil)
    end

    def estimated_text_cost(model_name, input_tokens: 0, output_tokens: 0)
      registry_model = registry_model_for(model_name)
      return if registry_model.blank?

      input_price = registry_model.respond_to?(:input_price_per_million) ? registry_model.input_price_per_million.to_f : 0.0
      output_price = registry_model.respond_to?(:output_price_per_million) ? registry_model.output_price_per_million.to_f : 0.0
      return if input_price.zero? && output_price.zero?

      ((input_tokens.to_f / 1_000_000) * input_price + (output_tokens.to_f / 1_000_000) * output_price).round(8)
    rescue StandardError
      nil
    end

    private

    def assume_exists_supported?(model_name)
      provider_for(model_name) == 'anthropic'
    end

    def normalize_capabilities(capabilities)
      Array(capabilities).filter_map do |capability|
        normalized_capability(capability)
      end.uniq
    end

    def normalized_capability(capability)
      capability_name = capability.to_s
      return if capability_name.blank?

      CAPABILITY_ALIASES.fetch(capability_name, capability_name)
    end

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
