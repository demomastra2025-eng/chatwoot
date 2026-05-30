# frozen_string_literal: true

class Llm::Runtime
  class << self
    def chat(request = nil, **attributes)
      feature_request = build_request(request, **attributes)
      provider_runtime(account: feature_request.account).chat(feature_request)
    end

    def transcribe(request = nil, **attributes)
      feature_request = build_request(request, feature: :audio_transcription, **attributes)
      provider_runtime(account: feature_request.account).transcribe(feature_request)
    end

    def embed(request = nil, **attributes)
      feature_request = build_request(request, feature: :embedding, **attributes)
      provider_runtime(account: feature_request.account).embed(feature_request)
    end

    def rerank(request = nil, **attributes)
      feature_request = build_request(request, feature: :knowledge_rerank, **attributes)
      provider_runtime(account: feature_request.account).rerank(feature_request)
    end

    def metadata(generation_id:, provider: :openrouter, account: nil)
      provider_runtime(provider: provider, account: account).metadata(generation_id)
    end

    def available_models(feature, account:, provider: :openrouter)
      provider_runtime(provider: provider, account: account).available_models(feature)
    end

    def diagnose_model(model_id, feature, account:, provider: :openrouter, runtime_preferences: nil)
      provider_runtime(provider: provider, account: account).diagnose_model(
        model_id,
        feature,
        runtime_preferences: runtime_preferences
      )
    end

    private

    def build_request(request = nil, **attributes)
      return request if request.is_a?(Llm::FeatureRequest)

      request_attributes = if request.respond_to?(:to_h)
                             request.to_h.symbolize_keys
                           else
                             {}
                           end
      Llm::FeatureRequest.new(**attributes, **request_attributes)
    end

    def provider_runtime(provider: :openrouter, account: nil)
      case provider.to_s
      when 'openrouter'
        Llm::OpenRouterRuntime.new(account: account)
      else
        raise ArgumentError, "Unsupported LLM runtime provider: #{provider}"
      end
    end
  end
end
