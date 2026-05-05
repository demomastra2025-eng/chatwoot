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
  OPENROUTER_PROVIDER = 'openrouter'.freeze
  OPENROUTER_DYNAMIC_FEATURE_REQUIREMENTS = {
    'editor' => [],
    'label_suggestion' => [],
    'assistant' => %w[structured_output tool_calling],
    'copilot' => %w[structured_output tool_calling]
  }.freeze

  class << self
    def providers = CONFIG['providers']
    def configured_models = CONFIG['models']
    def models = configured_models.merge(dynamic_model_configs)
    def features = CONFIG['features']
    def feature_keys = CONFIG['features'].keys

    def canonical_model_name(model_name)
      LEGACY_MODEL_ALIASES.fetch(model_name.to_s, model_name.to_s)
    end

    def default_model_for(feature)
      canonical_model_name(CONFIG.dig('features', feature.to_s, 'default'))
    end

    def models_for(feature)
      static_models = Array(CONFIG.dig('features', feature.to_s, 'models')).map { |model_name| canonical_model_name(model_name) }

      (static_models + dynamic_models_for_feature(feature.to_s)).uniq
    end

    def valid_model_for?(feature, model_name)
      models_for(feature).include?(canonical_model_name(model_name))
    end

    def model_config(model_name)
      canonical_name = canonical_model_name(model_name)
      configured_models[canonical_name] || dynamic_model_configs[canonical_name]
    end

    def provider_for(model_name)
      model_config(model_name)&.fetch('provider', nil) || inferred_dynamic_provider_for(model_name)
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
      return true if dynamic_model_configs.key?(canonical_model_name(model_name))

      registry_model_for(model_name).present?
    end

    def runtime_supported?(model_name)
      registry_known?(model_name) || assume_exists_supported?(model_name)
    end

    def feature_config(feature_key)
      feature = features[feature_key.to_s]
      return nil unless feature

      {
        models: models_for(feature_key).map do |model_name|
          canonical_name = canonical_model_name(model_name)
          model = model_config(canonical_name).to_h
          provider = model['provider']
          provider_metadata = provider_config(provider)
          {
            id: canonical_name,
            display_name: model['display_name'].presence || canonical_name,
            provider: provider,
            provider_display_name: provider_metadata&.fetch('display_name', nil) || provider,
            coming_soon: model['coming_soon'],
            credit_multiplier: model['credit_multiplier'],
            capabilities: capabilities_for(canonical_name),
            type: type_for(canonical_name),
            known_to_registry: registry_known?(canonical_name),
            source: model['source'],
            context_length: model['context_length'],
            max_output_tokens: model['max_output_tokens']
          }
        end,
        default: default_model_for(feature_key)
      }
    end

    def credit_multiplier_for(model_name)
      model_config(model_name)&.fetch('credit_multiplier', nil)
    end

    def estimated_text_cost(model_name, input_tokens: 0, output_tokens: 0)
      openrouter_cost = Llm::OpenRouterModelCatalog.estimated_text_cost(
        model_name,
        input_tokens: input_tokens,
        output_tokens: output_tokens
      )
      return openrouter_cost if openrouter_cost.present?

      registry_model = registry_model_for(model_name)
      return if registry_model.blank?

      input_price = registry_model.respond_to?(:input_price_per_million) ? registry_model.input_price_per_million.to_f : 0.0
      output_price = registry_model.respond_to?(:output_price_per_million) ? registry_model.output_price_per_million.to_f : 0.0
      return if input_price.zero? && output_price.zero?

      input_cost = (input_tokens.to_f / 1_000_000) * input_price
      output_cost = (output_tokens.to_f / 1_000_000) * output_price

      (input_cost + output_cost).round(8)
    rescue StandardError
      nil
    end

    private

    def dynamic_model_configs
      Llm::OpenRouterModelCatalog.model_configs
    end

    def dynamic_models_for_feature(feature_key)
      required_capabilities = OPENROUTER_DYNAMIC_FEATURE_REQUIREMENTS[feature_key]
      return [] if required_capabilities.nil?

      dynamic_model_configs.filter_map do |model_name, model_config|
        model_name if dynamic_model_allowed_for_feature?(model_config, required_capabilities)
      end
    end

    def dynamic_model_allowed_for_feature?(model_config, required_capabilities)
      return false unless model_config['provider'] == OPENROUTER_PROVIDER
      return false unless model_config['type'] == 'chat'

      required_capabilities.all? { |capability| Array(model_config['capabilities']).include?(capability) }
    end

    def inferred_dynamic_provider_for(model_name)
      return OPENROUTER_PROVIDER if openrouter_model_id?(model_name)

      nil
    end

    def openrouter_model_id?(model_name)
      dynamic_model_configs.key?(canonical_model_name(model_name)) && providers.key?(OPENROUTER_PROVIDER)
    end

    def assume_exists_supported?(model_name)
      %w[anthropic openrouter].include?(provider_for(model_name))
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
