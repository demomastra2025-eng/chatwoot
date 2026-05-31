# frozen_string_literal: true

module Llm::Evals::OpenRouterContractPolicyChecks
  include Llm::Evals::OpenRouterContractSupport

  private

  def openrouter_routing_contract
    exacto = routing_profile(:captain_agent, 'exacto')
    auto = routing_profile(:copilot, 'auto_exacto')
    failures = routing_failures(exacto, auto)

    {
      exacto_provider: exacto.provider_preferences,
      auto_exacto_provider: auto.provider_preferences,
      expected: { exacto_fallbacks: false, auto_exacto_fallbacks: true, order: %w[OpenAI Anthropic] },
      failures: failures
    }
  end

  def openrouter_native_endpoint_contract
    endpoints = {
      embedding: Llm::OpenRouterRoutingProfile.for(feature: :embedding, model: 'openai/text-embedding-3-small').native_endpoint,
      audio_transcription: Llm::OpenRouterRoutingProfile.for(
        feature: :audio_transcription,
        model: 'openai/gpt-4o-mini-transcribe'
      ).native_endpoint,
      knowledge_rerank: Llm::OpenRouterRoutingProfile.for(feature: :knowledge_rerank, model: 'rerank/model').native_endpoint
    }
    expected = { embedding: '/embeddings', audio_transcription: '/audio/transcriptions', knowledge_rerank: '/rerank' }

    { endpoints: endpoints, expected: expected, failures: endpoint_failures(endpoints, expected) }
  end

  def openrouter_privacy_contract
    account = ContractAccount.new(id: 42, captain_preferences: { runtime: { privacy_profile: 'zdr_required' } })
    provider = compile_contract_request(feature: :captain_agent, account: account).params[:provider].to_h

    {
      provider: provider,
      expected: { zdr: true, allow_fallbacks: false, data_collection: 'deny' },
      failures: privacy_failures(provider)
    }
  end

  def routing_failures(exacto, auto)
    failures = []
    failures << 'Exacto must disable fallbacks' unless exacto.provider_preferences[:allow_fallbacks] == false
    failures << 'Auto Exacto must keep fallbacks enabled' unless auto.provider_preferences[:allow_fallbacks] == true
    failures << 'Exacto provider order missing' unless exacto.provider_preferences[:order] == %w[OpenAI Anthropic]
    failures << 'Auto Exacto provider order missing' unless auto.provider_preferences[:order] == %w[OpenAI Anthropic]
    failures
  end

  def endpoint_failures(endpoints, expected)
    expected.filter_map { |key, endpoint| "#{key} native endpoint mismatch" unless endpoints[key] == endpoint }
  end

  def privacy_failures(provider)
    failures = []
    failures << 'ZDR must be enabled' unless provider[:zdr] == true
    failures << 'fallbacks must be disabled for ZDR' unless provider[:allow_fallbacks] == false
    failures << 'data collection must be denied for ZDR' unless provider[:data_collection] == 'deny'
    failures
  end
end
