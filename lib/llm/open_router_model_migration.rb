# frozen_string_literal: true

class Llm::OpenRouterModelMigration
  VOICE_FEATURES = %w[
    voice_settings
    ai_voice_settings
    voice
    ai_voice
    telephony_ai_voice
    realtime_voice
    gemini_live
  ].freeze

  EXACT_MAPPINGS = {
    'whisper-1' => %w[openai/whisper-large-v3 openai/gpt-4o-mini-transcribe openai/gpt-4o-transcribe],
    'gpt-4o-transcribe' => %w[openai/gpt-4o-transcribe openai/gpt-4o-mini-transcribe],
    'omni-moderation-latest' => %w[openai/gpt-oss-safeguard-20b meta-llama/llama-guard-4-12b meta-llama/llama-guard-3-8b],
    'text-embedding-3-small' => %w[openai/text-embedding-3-small text-embedding-3-small]
  }.freeze

  class << self
    def resolve(model_name, feature:, account: nil)
      canonical_model = Llm::Models.canonical_model_name(model_name)
      return if canonical_model.blank?
      return canonical_model if voice_feature?(feature)
      return canonical_model unless openrouter_required_for?(feature, account: account)

      candidates_for(canonical_model).find do |candidate|
        Llm::Models.valid_model_for?(feature, candidate, account: account)
      end
    end

    def candidates_for(model_name)
      canonical_model = Llm::Models.canonical_model_name(model_name)
      return [] if canonical_model.blank?

      candidates = []
      candidates << canonical_model if canonical_model.include?('/')
      candidates.concat(EXACT_MAPPINGS.fetch(canonical_model, []))
      candidates << "openai/#{canonical_model}" if openai_model_id?(canonical_model)
      candidates << "anthropic/#{canonical_model}" if anthropic_model_id?(canonical_model)
      candidates << "google/#{canonical_model}" if gemini_model_id?(canonical_model)
      candidates << canonical_model
      candidates.compact_blank.uniq
    end

    def migrate_models_hash(models_hash, account: nil)
      models_hash.to_h.each_with_object({}) do |(feature, model_name), result|
        result[feature.to_s] = resolve(model_name, feature: feature, account: account) || Llm::Models.canonical_model_name(model_name)
      end
    end

    def voice_feature?(feature)
      VOICE_FEATURES.include?(feature.to_s)
    end

    private

    def openrouter_required_for?(feature, account: nil)
      Llm::Models.openrouter_no_fallback_active_for?(feature, account: account)
    end

    def openai_model_id?(model_name)
      model_name.start_with?('gpt-')
    end

    def anthropic_model_id?(model_name)
      model_name.start_with?('claude-')
    end

    def gemini_model_id?(model_name)
      model_name.start_with?('gemini-')
    end
  end
end
