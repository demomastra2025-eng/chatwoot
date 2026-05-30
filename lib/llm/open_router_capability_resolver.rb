# frozen_string_literal: true

class Llm::OpenRouterCapabilityResolver
  OPENROUTER_PROVIDER = Llm::OpenRouterModelCatalog::PROVIDER
  PARAMETER_CAPABILITIES = %w[tool_calling structured_output reasoning].freeze
  EMBEDDING_DIMENSION_FEATURES = %w[help_center_search embedding].freeze

  Result = Struct.new(:model_id, :feature, :allowed, :reasons, :missing, :model_config, :endpoint_metadata, keyword_init: true) do
    def allowed?
      allowed == true
    end

    def to_h
      {
        model_id: model_id,
        feature: feature,
        allowed: allowed?,
        reasons: reasons,
        missing: missing,
        endpoint_count: Array(endpoint_metadata.to_h['endpoints']).size,
        endpoint_providers: Array(endpoint_metadata.to_h['providers'])
      }.compact
    end
  end

  class << self
    def call(model_id:, feature:, account: nil, runtime_preferences: nil, runtime_filtered: true)
      feature_key = feature.to_s
      canonical_model = Llm::Models.canonical_model_name(model_id)
      model_config = Llm::Models.model_config(canonical_model, account: account).to_h
      endpoint_metadata = Llm::OpenRouterEndpointCatalog.endpoint_metadata(canonical_model).to_h
      reasons = []
      missing = []

      if canonical_model.blank?
        reasons << reason('model_not_found', 'Model id is blank.')
        return result(canonical_model, feature_key, false, reasons, missing, model_config, endpoint_metadata)
      end

      provider = model_config['provider'].presence || Llm::Models.provider_for(canonical_model, account: account)
      visibility_reason = Llm::ProviderVisibilityPolicy.hidden_reason(provider) if provider.present?
      reasons << reason(visibility_reason, provider_hidden_message(provider), provider: provider) if visibility_reason.present?

      if model_config.blank?
        reasons << reason('model_not_found', 'Model is not present in the OpenRouter catalog or static model config.')
        return result(canonical_model, feature_key, false, reasons, missing, model_config, endpoint_metadata)
      end

      unless provider == OPENROUTER_PROVIDER
        if visibility_reason.blank?
          reasons << reason('direct_provider_disabled', 'Direct provider models are disabled for normal Captain settings.', provider: provider)
        end
        return result(canonical_model, feature_key, false, reasons.uniq, missing, model_config, endpoint_metadata)
      end

      unless Llm::Config.provider_available?(OPENROUTER_PROVIDER, account: account)
        reasons << reason('provider_not_configured', 'OpenRouter provider key is not configured.', provider: OPENROUTER_PROVIDER)
      end

      requirement_sets = Llm::Models.required_capability_sets_for(feature_key)
      return result(canonical_model, feature_key, reasons.empty?, reasons, missing, model_config, endpoint_metadata) if requirement_sets.blank?

      allowed_by_requirements = requirement_sets.any? do |requirement|
        missing_for_requirement = missing_for_requirement(model_config, endpoint_metadata, requirement)
        missing_for_requirement.empty?
      end

      unless allowed_by_requirements
        missing = best_missing_capabilities(model_config, endpoint_metadata, requirement_sets)
        reasons.concat(reasons_for_missing_capabilities(missing))
        if type_mismatch?(model_config, requirement_sets)
          reasons << reason('unsupported_type', unsupported_type_message(model_config, requirement_sets), type: model_config['type'])
        end
      end

      zdr_reason = zdr_required_reason(endpoint_metadata, account: account, runtime_preferences: runtime_preferences)
      reasons << zdr_reason if zdr_reason.present?

      if embedding_feature?(feature_key)
        embedding_reason = embedding_dimension_reason(model_config)
        reasons << embedding_reason if embedding_reason.present?

        context_reason = context_reason(model_config, account: account, runtime_preferences: runtime_preferences) if runtime_filtered
        reasons << context_reason if context_reason.present?
      end

      result(canonical_model, feature_key, reasons.empty?, reasons.uniq, missing.uniq, model_config, endpoint_metadata)
    rescue StandardError => e
      result(
        model_id.to_s,
        feature.to_s,
        false,
        [reason('capability_diagnostics_failed', "Capability diagnostics failed: #{e.class}")],
        [],
        {},
        {}
      )
    end

    private

    def result(model_id, feature, allowed, reasons, missing, model_config, endpoint_metadata)
      Result.new(
        model_id: model_id,
        feature: feature,
        allowed: allowed,
        reasons: reasons,
        missing: missing,
        model_config: model_config,
        endpoint_metadata: endpoint_metadata
      )
    end

    def missing_for_requirement(model_config, endpoint_metadata, requirement)
      missing = []
      required_type = requirement[:type].presence
      missing << "type:#{required_type}" if required_type.present? && model_config['type'] != required_type

      capabilities = Array(model_config['capabilities']).map(&:to_s)
      missing.concat(Array(requirement[:capabilities]).map(&:to_s) - capabilities)
      missing.concat(endpoint_missing_parameter_capabilities(endpoint_metadata, requirement))
      missing.uniq
    end

    def endpoint_missing_parameter_capabilities(endpoint_metadata, requirement)
      required_parameter_capabilities = Array(requirement[:capabilities]).map(&:to_s) & PARAMETER_CAPABILITIES
      return [] if required_parameter_capabilities.blank?

      endpoints = Array(endpoint_metadata['endpoints'])
      return [] if endpoints.blank?

      return [] if endpoints.any? do |endpoint|
        endpoint_capabilities = Array(endpoint['capabilities']).map(&:to_s)
        (required_parameter_capabilities - endpoint_capabilities).empty?
      end

      required_parameter_capabilities
    end

    def best_missing_capabilities(model_config, endpoint_metadata, requirement_sets)
      requirement_sets.map { |requirement| missing_for_requirement(model_config, endpoint_metadata, requirement) }
                      .min_by(&:length)
                      .to_a
                      .reject { |value| value.start_with?('type:') }
    end

    def reasons_for_missing_capabilities(missing_capabilities)
      missing_capabilities.map do |capability|
        case capability
        when 'structured_output'
          reason('structured_output_unsupported', 'Model does not support structured output.', capability: capability)
        when 'tool_calling'
          reason('tool_calling_unsupported', 'Model does not support tool calling.', capability: capability)
        else
          reason('missing_capability', "Model does not support #{capability.tr('_', ' ')}.", capability: capability)
        end
      end
    end

    def type_mismatch?(model_config, requirement_sets)
      required_types = requirement_sets.filter_map { |requirement| requirement[:type].presence }.uniq
      required_types.present? && required_types.exclude?(model_config['type'])
    end

    def unsupported_type_message(model_config, requirement_sets)
      required_types = requirement_sets.filter_map { |requirement| requirement[:type].presence }.uniq.join(', ')
      "Model type #{model_config['type'].presence || 'unknown'} is not supported for this feature; expected #{required_types}."
    end

    def embedding_feature?(feature_key)
      EMBEDDING_DIMENSION_FEATURES.include?(feature_key.to_s)
    end

    def embedding_dimension_reason(model_config)
      requested_dimensions = model_config['requested_embedding_dimensions'].presence || model_config['embedding_dimensions']
      return if requested_dimensions.blank?
      return if requested_dimensions.to_i == Captain::KnowledgeSettings::VECTOR_DIMENSIONS

      reason(
        'embedding_dimension_mismatch',
        'Embedding dimensions do not match the OneLink knowledge index.',
        expected: Captain::KnowledgeSettings::VECTOR_DIMENSIONS,
        actual: requested_dimensions.to_i
      )
    end

    def zdr_required_reason(endpoint_metadata, account:, runtime_preferences:)
      privacy_policy = Llm::OpenRouterWorkspacePolicy.resolve(account: account, preferences: runtime_preferences)
      return unless privacy_policy.zdr_required?

      endpoints = Array(endpoint_metadata['endpoints'])
      unless endpoints.any? { |endpoint| ActiveModel::Type::Boolean.new.cast(endpoint['zdr']) }
        return reason(
          'zdr_required_unsupported',
          'No refreshed OpenRouter endpoint for this model advertises zero data retention.',
          providers: Array(endpoint_metadata['providers'])
        )
      end
    rescue ArgumentError => e
      reason('privacy_profile_invalid', e.message)
    end

    def context_reason(model_config, account:, runtime_preferences:)
      context_length = model_config['context_length'].to_i
      estimated_tokens = if runtime_preferences.to_h.key?(:knowledge_chunk_size) || runtime_preferences.to_h.key?('knowledge_chunk_size')
                           chunk_size = runtime_preferences.to_h[:knowledge_chunk_size] || runtime_preferences.to_h['knowledge_chunk_size']
                           Captain::KnowledgeSettings.estimated_tokens_for_chunk_size(chunk_size)
                         else
                           Captain::KnowledgeSettings.estimated_tokens_for_account(account)
                         end
      if context_length <= 0
        return reason(
          'context_too_small',
          'Model context is unknown for the configured knowledge chunk size.',
          context_length: context_length,
          required_context_tokens: estimated_tokens
        )
      end

      return if context_length >= estimated_tokens

      reason(
        'context_too_small',
        'Model context is too small for the configured knowledge chunk size.',
        context_length: context_length,
        required_context_tokens: estimated_tokens
      )
    end

    def provider_hidden_message(provider)
      if Llm::ProviderVisibilityPolicy.voice_provider?(provider)
        'Gemini direct provider is available only for AI Voice.'
      else
        'Direct provider is disabled for normal Captain settings.'
      end
    end

    def reason(code, message, details = {})
      {
        code: code,
        message: message,
        details: details.compact
      }
    end
  end
end
