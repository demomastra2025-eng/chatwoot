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
    'moderation' => %w[moderation text_input],
    'rerank' => %w[rerank text_input text_output],
    'transcription' => %w[transcription]
  }.freeze
  OPENROUTER_PROVIDER = 'openrouter'.freeze
  OPENROUTER_DYNAMIC_FEATURE_REQUIREMENTS = {
    'editor' => [],
    'label_suggestion' => [],
    'assistant' => %w[structured_output tool_calling],
    'copilot' => %w[structured_output tool_calling],
    'audio_transcription' => %w[audio_input transcription],
    'image_recognition' => %w[image_input],
    'help_center_search' => %w[embedding],
    'knowledge_rerank' => %w[rerank text_input text_output],
    'moderation' => %w[text_input text_output structured_output moderation]
  }.freeze
  OPENROUTER_DYNAMIC_FEATURE_REQUIREMENT_SETS = {
    'audio_transcription' => [
      { type: 'transcription', capabilities: %w[audio_input transcription] },
      { type: 'chat', capabilities: %w[audio_input text_output transcription] }
    ],
    'knowledge_rerank' => [
      { type: 'rerank', capabilities: %w[rerank text_input text_output] }
    ]
  }.freeze
  OPENROUTER_NO_FALLBACK_FEATURES = OPENROUTER_DYNAMIC_FEATURE_REQUIREMENTS.keys.freeze
  OPENROUTER_PREFERRED_FEATURE_MODELS = {
    'audio_transcription' => %w[
      openai/gpt-4o-mini-transcribe
      openai/gpt-4o-transcribe
      openai/whisper-large-v3
      openai/gpt-audio-mini
      openai/gpt-audio
      mistralai/voxtral-small-24b-2507
    ],
    'moderation' => %w[
      openai/gpt-oss-safeguard-20b
      meta-llama/llama-guard-4-12b
      meta-llama/llama-guard-3-8b
    ]
  }.freeze
  DIAGNOSTIC_MODEL_LIMIT = 120

  class << self
    def providers = CONFIG['providers']
    def configured_models = CONFIG['models']
    def models(account: nil) = configured_models.merge(dynamic_model_configs(account: account))
    def features = CONFIG['features']
    def feature_keys = CONFIG['features'].keys

    def canonical_model_name(model_name)
      LEGACY_MODEL_ALIASES.fetch(model_name.to_s, model_name.to_s)
    end

    def configured_default_model_for(feature)
      canonical_model_name(CONFIG.dig('features', feature.to_s, 'default'))
    end

    def default_model_for(feature, account: nil)
      feature_key = feature.to_s
      configured_default = configured_default_model_for(feature_key)

      if openrouter_only_feature?(feature_key)
        openrouter_default = openrouter_default_model_for(feature_key, configured_default, account: account)
        return openrouter_default if openrouter_default.present?

        return
      end

      configured_provider = provider_for(configured_default, account: account)
      return configured_default if configured_provider.present? &&
                                   configured_provider != OPENROUTER_PROVIDER &&
                                   Llm::Config.provider_available?(configured_provider, account: account)

      openrouter_default = openrouter_default_model_for(feature_key, configured_default, account: account)
      return openrouter_default if openrouter_default.present?
      return if Llm::ProviderVisibilityPolicy.normal_captain_provider?(configured_provider) &&
                openrouter_no_fallback_active_for?(feature_key, account: account)

      configured_default
    end

    def required_capabilities_for(feature)
      OPENROUTER_DYNAMIC_FEATURE_REQUIREMENTS.fetch(feature.to_s, [])
    end

    def required_capability_sets_for(feature)
      feature_key = feature.to_s
      required_capabilities = required_capabilities_for(feature_key)
      return [{ type: 'chat', capabilities: [] }] if required_capabilities.blank? && OPENROUTER_DYNAMIC_FEATURE_REQUIREMENTS.key?(feature_key)
      return [] if required_capabilities.blank?

      OPENROUTER_DYNAMIC_FEATURE_REQUIREMENT_SETS.fetch(feature_key) do
        required_type = required_capabilities.include?('embedding') ? 'embedding' : 'chat'
        [{ type: required_type, capabilities: required_capabilities }]
      end
    end

    def capability_diagnostics_for(feature, model_name, account: nil, runtime_preferences: nil, runtime_filtered: true)
      Llm::OpenRouterCapabilityResolver.call(
        model_id: model_name,
        feature: feature,
        account: account,
        runtime_preferences: runtime_preferences,
        runtime_filtered: runtime_filtered
      )
    end

    def openrouter_no_fallback_active_for?(feature, account: nil)
      OPENROUTER_NO_FALLBACK_FEATURES.include?(feature.to_s) && openrouter_catalog_enabled?(account: account)
    end

    def models_for(feature, account: nil, runtime_filtered: true)
      feature_key = feature.to_s
      static_models = Array(CONFIG.dig('features', feature_key, 'models')).map { |model_name| canonical_model_name(model_name) }
      dynamic_models = dynamic_models_for_feature(feature_key, account: account, runtime_filtered: runtime_filtered)

      if openrouter_no_fallback_active_for?(feature_key, account: account)
        static_fallback_models = account_static_models_for_feature(feature_key, static_models, account, runtime_filtered: runtime_filtered)
        return (dynamic_models.presence || static_fallback_models).uniq if feature_key == 'help_center_search'

        return (dynamic_models + static_fallback_models).uniq
      end

      (static_models + dynamic_models).uniq
    end

    def valid_model_for?(feature, model_name, account: nil)
      models_for(feature, account: account).include?(canonical_model_name(model_name))
    end

    def configured_model_for_feature?(feature, model_name, account: nil)
      Array(CONFIG.dig('features', feature.to_s, 'models'))
        .map { |configured_model| canonical_model_name(configured_model) }
        .include?(canonical_model_name(model_name)) &&
        model_config_allowed_for_feature?(feature.to_s, model_config(model_name, account: account), account: account)
    end

    def model_config(model_name, account: nil)
      canonical_name = canonical_model_name(model_name)
      dynamic_config = dynamic_model_configs(account: account)[canonical_name]
      return dynamic_config if dynamic_config.to_h['provider'] == OPENROUTER_PROVIDER

      configured_models[canonical_name] || dynamic_config
    end

    def provider_for(model_name, account: nil)
      model_config(model_name, account: account)&.fetch('provider', nil) || inferred_dynamic_provider_for(model_name, account: account)
    end

    def provider_config(provider_name)
      providers&.fetch(provider_name.to_s, nil)
    end

    def type_for(model_name, account: nil)
      model_config(model_name, account: account)&.fetch('type', nil) || registry_info_for(model_name)&.type
    end

    def capabilities_for(model_name, account: nil)
      canonical_name = canonical_model_name(model_name)
      resolved_config = model_config(canonical_name, account: account)
      normalize_capabilities(
        Array(resolved_config&.fetch('capabilities', nil)) +
        registry_capabilities_for(canonical_name, resolved_config, account: account) +
        TYPE_CAPABILITIES.fetch(type_for(canonical_name, account: account).to_s, [])
      )
    end

    def supports?(model_name, capability, account: nil)
      capabilities_for(model_name, account: account).include?(capability.to_s)
    end

    def supports_thinking?(model_name, account: nil)
      supports?(model_name, :reasoning, account: account)
    end

    def supports_structured_output?(model_name, account: nil)
      supports?(model_name, :structured_output, account: account)
    end

    def supports_tool_calling?(model_name, account: nil)
      supports?(model_name, :tool_calling, account: account)
    end

    def supports_multimodal_input?(model_name, account: nil)
      supports?(model_name, :multimodal_input, account: account)
    end

    def supports_image_input?(model_name, account: nil)
      supports?(model_name, :image_input, account: account)
    end

    def supports_audio_input?(model_name, account: nil)
      supports?(model_name, :audio_input, account: account)
    end

    def supports_streaming?(model_name, account: nil)
      supports?(model_name, :streaming, account: account)
    end

    def supports_embedding?(model_name, account: nil)
      supports?(model_name, :embedding, account: account)
    end

    def knowledge_chunk_size_options(account: nil)
      embedding_model_configs_for_chunk_options(account: account).then do |model_configs|
        chunk_sizes = Captain::KnowledgeSettings.chunk_size_options_for_context_lengths(
          model_configs.filter_map { |model_config| model_config['context_length'] },
          include_values: [
            Captain::KnowledgeSettings::DEFAULT_CHUNK_SIZE,
            Captain::KnowledgeSettings.chunk_size_for(account)
          ]
        )

        chunk_sizes.map do |chunk_size|
          estimated_tokens = Captain::KnowledgeSettings.estimated_tokens_for_chunk_size(chunk_size)
          available_model_count = model_configs.count do |model_config|
            embedding_model_supports_estimated_tokens?(model_config, estimated_tokens: estimated_tokens)
          end

          {
            value: chunk_size,
            estimated_tokens: estimated_tokens,
            available_model_count: available_model_count,
            disabled: available_model_count.zero?
          }
        end
      end
    end

    def supports_transcription?(model_name, account: nil)
      supports?(model_name, :transcription, account: account)
    end

    def registry_model_for(model_name)
      RubyLLM.models.find(canonical_model_name(model_name))
    rescue StandardError
      nil
    end

    def registry_known?(model_name, account: nil)
      return true if dynamic_model_configs(account: account).key?(canonical_model_name(model_name))

      registry_model_for(model_name).present?
    end

    def runtime_supported?(model_name, account: nil)
      known = account.present? ? registry_known?(model_name, account: account) : registry_known?(model_name)
      known || assume_exists_supported?(model_name, account: account)
    end

    def feature_config(feature_key, account: nil)
      feature = features[feature_key.to_s]
      return nil unless feature

      provider_status = provider_status_by_name(account)
      runtime_preferences = runtime_preferences_for(account)
      feature_model_names = feature_config_models_for(feature_key, account: account)
      {
        models: feature_model_names.filter_map do |model_name|
          canonical_name = canonical_model_name(model_name)
          model = model_config(canonical_name, account: account).to_h
          provider = model['provider']
          provider_metadata = provider_config(provider)
          status = provider_status[provider].to_h
          next if account.present? && status[:configured] != true

          diagnostics = openrouter_capability_diagnostics_for(
            feature_key,
            canonical_name,
            account: account,
            runtime_preferences: runtime_preferences,
            runtime_filtered: feature_key.to_s != 'help_center_search'
          )

          {
            id: canonical_name,
            display_name: model['display_name'].presence || canonical_name,
            provider: provider,
            provider_display_name: provider_metadata&.fetch('display_name', nil) || provider,
            provider_configured: status[:configured] == true,
            account_configured: status[:account_configured] == true,
            global_configured: status[:global_configured] == true,
            coming_soon: model['coming_soon'],
            credit_multiplier: model['credit_multiplier'],
            capabilities: capabilities_for(canonical_name, account: account),
            type: type_for(canonical_name, account: account),
            known_to_registry: registry_known?(canonical_name, account: account),
            source: model['source'],
            context_length: model['context_length'],
            max_output_tokens: model['max_output_tokens'],
            input_modalities: model['input_modalities'],
            output_modalities: model['output_modalities'],
            embedding_dimensions: model['embedding_dimensions'],
            requested_embedding_dimensions: model['requested_embedding_dimensions'],
            pricing: model['pricing'],
            latency_ms: model['latency_ms'],
            throughput_tokens_per_second: model['throughput_tokens_per_second'],
            diagnostics: diagnostics&.to_h
          }
        end,
        diagnostic_models: diagnostic_models_for_feature(
          feature_key,
          feature_model_names,
          provider_status,
          account: account,
          runtime_preferences: runtime_preferences
        ),
        default: default_model_for(feature_key, account: account),
        configured_default: configured_default_model_for(feature_key),
        required_capabilities: required_capabilities_for(feature_key)
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

    def dynamic_model_configs(account: nil)
      return {} unless openrouter_catalog_enabled?(account: account)

      Llm::OpenRouterModelCatalog.model_configs
    end

    def account_static_models_for_feature(feature_key, static_models, account, runtime_filtered: true)
      static_models.select do |model_name|
        provider = provider_for(model_name, account: account)
        provider == OPENROUTER_PROVIDER &&
          Llm::Config.provider_available?(provider, account: account) &&
          model_config_allowed_for_feature?(
            feature_key,
            model_config(model_name, account: account),
            account: account,
            runtime_filtered: runtime_filtered
          )
      end
    rescue StandardError
      []
    end

    def openrouter_only_feature?(feature_key)
      OPENROUTER_DYNAMIC_FEATURE_REQUIREMENTS.key?(feature_key.to_s)
    end

    def openrouter_default_model_for(feature_key, configured_default, account: nil)
      return unless openrouter_only_feature?(feature_key)
      return unless openrouter_catalog_enabled?(account: account)

      required_capabilities = required_capabilities_for(feature_key)
      openrouter_default_candidates(feature_key, configured_default, account: account).find do |candidate|
        candidate_config = model_config(candidate, account: account)
        dynamic_model_allowed_for_feature?(
          feature_key,
          candidate_config,
          required_capabilities,
          account: account,
          runtime_preferences: runtime_preferences_for(account),
          model_id: candidate
        )
      end
    end

    def openrouter_capability_diagnostics_for(feature_key, model_name, account: nil, runtime_preferences: nil, runtime_filtered: true)
      return unless openrouter_only_feature?(feature_key)

      capability_diagnostics_for(
        feature_key,
        model_name,
        account: account,
        runtime_preferences: runtime_preferences,
        runtime_filtered: runtime_filtered
      )
    end

    def openrouter_default_candidates(feature_key, configured_default, account: nil)
      candidates = [openrouter_equivalent_model_id(configured_default, account: account)]
      candidates << canonical_model_name(configured_default)
      candidates.concat(OPENROUTER_PREFERRED_FEATURE_MODELS.fetch(feature_key, []))
      candidates.concat(dynamic_models_for_feature(feature_key, account: account))
      candidates.compact_blank.uniq
    end

    def openrouter_equivalent_model_id(configured_default, account: nil)
      configured_default = canonical_model_name(configured_default)
      return if configured_default.blank?
      return configured_default if dynamic_model_configs(account: account).key?(configured_default)

      "openai/#{configured_default}"
    end

    def feature_config_models_for(feature_key, account: nil)
      runtime_filtered = feature_key.to_s != 'help_center_search'
      model_names = models_for(feature_key, account: account, runtime_filtered: runtime_filtered)
      return model_names unless openrouter_only_feature?(feature_key)

      model_names.select do |model_name|
        Llm::ProviderVisibilityPolicy.normal_captain_provider?(provider_for(model_name, account: account))
      end
    end

    def dynamic_models_for_feature(feature_key, account: nil, runtime_filtered: true)
      required_capabilities = OPENROUTER_DYNAMIC_FEATURE_REQUIREMENTS[feature_key]
      return [] if required_capabilities.nil?

      dynamic_model_configs(account: account).filter_map do |model_name, model_config|
        if dynamic_model_allowed_for_feature?(
          feature_key,
          model_config,
          required_capabilities,
          account: account,
          runtime_preferences: runtime_preferences_for(account),
          runtime_filtered: runtime_filtered,
          model_id: model_name
        )
          model_name
        end
      end
    end

    def diagnostic_models_for_feature(feature_key, allowed_model_names, provider_status, account: nil, runtime_preferences: nil)
      return [] unless openrouter_only_feature?(feature_key)

      allowed_model_ids = allowed_model_names.map { |model_name| canonical_model_name(model_name) }
      runtime_filtered = feature_key.to_s != 'help_center_search'

      diagnostic_model_candidates(account: account).each_with_object([]) do |canonical_name, result|
        break result if result.size >= DIAGNOSTIC_MODEL_LIMIT
        next if allowed_model_ids.include?(canonical_name)

        model = model_config(canonical_name, account: account).to_h
        provider = model['provider']
        next unless Llm::ProviderVisibilityPolicy.normal_captain_provider?(provider)

        status = provider_status[provider].to_h
        next if account.present? && status[:configured] != true

        diagnostics = openrouter_capability_diagnostics_for(
          feature_key,
          canonical_name,
          account: account,
          runtime_preferences: runtime_preferences,
          runtime_filtered: runtime_filtered
        )
        next if diagnostics.blank? || diagnostics.allowed?

        provider_metadata = provider_config(provider)
        result << {
          id: canonical_name,
          display_name: model['display_name'].presence || canonical_name,
          provider: provider,
          provider_display_name: provider_metadata&.fetch('display_name', nil) || provider,
          provider_configured: status[:configured] == true,
          account_configured: status[:account_configured] == true,
          global_configured: status[:global_configured] == true,
          coming_soon: model['coming_soon'],
          capabilities: capabilities_for(canonical_name, account: account),
          type: type_for(canonical_name, account: account),
          known_to_registry: registry_known?(canonical_name, account: account),
          source: model['source'],
          context_length: model['context_length'],
          max_output_tokens: model['max_output_tokens'],
          input_modalities: model['input_modalities'],
          output_modalities: model['output_modalities'],
          embedding_dimensions: model['embedding_dimensions'],
          requested_embedding_dimensions: model['requested_embedding_dimensions'],
          pricing: model['pricing'],
          latency_ms: model['latency_ms'],
          throughput_tokens_per_second: model['throughput_tokens_per_second'],
          diagnostics: diagnostics.to_h,
          diagnostic_only: true
        }
      end
    rescue StandardError
      []
    end

    def diagnostic_model_candidates(account: nil)
      models(account: account).keys.map { |model_name| canonical_model_name(model_name) }.uniq
    end

    def dynamic_model_allowed_for_feature?(feature_key, model_config, _required_capabilities, account: nil, runtime_preferences: nil,
                                           runtime_filtered: true, model_id: nil)
      return false if model_config.blank?
      return false unless model_config['provider'] == OPENROUTER_PROVIDER

      diagnostics = Llm::OpenRouterCapabilityResolver.call(
        model_id: model_id.presence || model_config['id'].presence || dynamic_model_id_for_config(model_config, account: account),
        feature: feature_key,
        account: account,
        runtime_preferences: runtime_preferences,
        runtime_filtered: runtime_filtered
      )
      return diagnostics.allowed? if diagnostics.model_config.present?

      return false unless model_config_allowed_for_feature?(feature_key, model_config, account: account, runtime_filtered: runtime_filtered)

      required_capability_sets_for(feature_key).any? do |requirement|
        requirement_type = requirement[:type]
        required = requirement[:capabilities]

        (requirement_type.blank? || model_config['type'] == requirement_type) &&
          required.all? { |capability| Array(model_config['capabilities']).include?(capability) }
      end
    end

    def dynamic_model_id_for_config(model_config, account: nil)
      dynamic_model_configs(account: account).find { |_model_id, config| config.equal?(model_config) || config == model_config }&.first
    end

    def model_config_allowed_for_feature?(feature_key, model_config, account: nil, runtime_filtered: true)
      return false if model_config.blank?
      return true unless feature_key.to_s == 'help_center_search'

      return embedding_model_supports_requested_dimensions?(model_config) unless runtime_filtered

      embedding_model_supports_knowledge_index?(model_config, account: account)
    end

    def embedding_model_supports_knowledge_index?(model_config, account: nil)
      embedding_model_supports_estimated_tokens?(
        model_config,
        estimated_tokens: Captain::KnowledgeSettings.estimated_tokens_for_account(account)
      )
    end

    def embedding_model_supports_estimated_tokens?(model_config, estimated_tokens:)
      context_length = model_config['context_length'].to_i

      embedding_model_supports_requested_dimensions?(model_config) &&
        context_length.positive? &&
        context_length >= estimated_tokens
    end

    def embedding_model_configs_for_chunk_options(account: nil)
      return [] unless openrouter_catalog_enabled?(account: account)

      dynamic_configs = dynamic_model_configs(account: account).values.select do |model_config|
        model_config['provider'] == OPENROUTER_PROVIDER &&
          model_config['type'] == 'embedding' &&
          Array(model_config['capabilities']).include?('embedding') &&
          embedding_model_supports_requested_dimensions?(model_config)
      end
      return dynamic_configs if dynamic_configs.present?

      static_configs = Array(CONFIG.dig('features', 'help_center_search', 'models')).filter_map do |model_name|
        model_config(model_name, account: account)
      end

      static_configs.select do |model_config|
        model_config['provider'] == OPENROUTER_PROVIDER &&
          model_config['type'] == 'embedding' &&
          embedding_model_supports_requested_dimensions?(model_config)
      end
    end

    def embedding_model_supports_requested_dimensions?(model_config)
      requested_dimensions = model_config['requested_embedding_dimensions'].presence || model_config['embedding_dimensions']
      return requested_dimensions.to_i == Captain::KnowledgeSettings::VECTOR_DIMENSIONS if requested_dimensions.present?

      model_config['provider'] == OPENROUTER_PROVIDER
    end

    def registry_capabilities_for(model_name, model_config, account: nil)
      return [] if dynamic_openrouter_model_config?(model_name, model_config, account: account)

      Array(registry_info_for(model_name)&.capabilities)
    end

    def dynamic_openrouter_model_config?(model_name, model_config, account: nil)
      model_config.to_h['provider'] == OPENROUTER_PROVIDER &&
        dynamic_model_configs(account: account).key?(canonical_model_name(model_name))
    end

    def runtime_preferences_for(account)
      return account.captain_runtime.to_h if account.respond_to?(:captain_runtime)
      return account.captain_preferences[:runtime].to_h if account.respond_to?(:captain_preferences)

      {}
    rescue StandardError
      {}
    end

    def provider_status_by_name(account)
      providers.keys.index_with do |provider_name|
        {
          configured: Llm::Config.provider_available?(provider_name, account: account),
          account_configured: Llm::Config.account_provider_available?(provider_name, account: account),
          global_configured: Llm::Config.installation_provider_available?(provider_name)
        }
      end
    end

    def inferred_dynamic_provider_for(model_name, account: nil)
      return OPENROUTER_PROVIDER if openrouter_model_id?(model_name, account: account)
      return OPENROUTER_PROVIDER if canonical_model_name(model_name).include?('/') && providers.key?(OPENROUTER_PROVIDER)

      nil
    end

    def openrouter_model_id?(model_name, account: nil)
      dynamic_model_configs(account: account).key?(canonical_model_name(model_name)) && providers.key?(OPENROUTER_PROVIDER)
    end

    def openrouter_catalog_enabled?(account: nil)
      if account.present?
        Llm::Config.provider_available?(OPENROUTER_PROVIDER, account: account)
      else
        Llm::Config.provider_available?(OPENROUTER_PROVIDER)
      end
    rescue StandardError
      false
    end

    def assume_exists_supported?(model_name, account: nil)
      %w[anthropic openrouter].include?(provider_for(model_name, account: account))
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
