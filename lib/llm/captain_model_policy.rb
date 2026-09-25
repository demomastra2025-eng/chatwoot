# frozen_string_literal: true

# Installation-level egress policy. The model catalog and account preferences
# select candidates; neither can authorize a Captain model not on this list.
class Llm::CaptainModelPolicy
  DEFAULT_MODEL = 'openai/gpt-5.6-luna'.freeze
  DisallowedModelError = Class.new(ArgumentError)

  class << self
    def allowed_models
      config = InstallationConfig.find_by(name: 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST')
      return [DEFAULT_MODEL] unless config

      raw = config.value
      models = raw.is_a?(String) ? JSON.parse(raw) : raw
      return [] unless models.is_a?(Array)

      models.filter_map do |model|
        Llm::Models.canonical_model_name(model.strip) if model.is_a?(String) && model.strip.present?
      end.uniq
    rescue JSON::ParserError
      Rails.logger.error('[LLM] Invalid Captain allowlist JSON; Captain egress disabled')
      []
    end

    def allowed?(model)
      allowed_models.include?(model.to_s.strip)
    end

    def ensure_allowed!(feature:, model:, fallback_models: nil)
      return unless captain_feature?(feature)

      raise DisallowedModelError, 'Captain model is missing' unless model.is_a?(String) && model.strip.present?

      models = [model, *Array(fallback_models)].flatten.compact

      rejected = models.reject { |candidate| candidate.is_a?(String) && allowed?(Llm::Models.canonical_model_name(candidate.strip)) }
      raise DisallowedModelError, "Captain model not allowed: #{rejected.map(&:to_s).join(', ')}" if rejected.any?
    end

    def captain_feature?(feature)
      Llm::FeatureProfile.normalize_feature(feature) == 'captain_agent'
    end
  end
end
