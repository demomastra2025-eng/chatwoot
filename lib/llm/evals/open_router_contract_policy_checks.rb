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

  def openrouter_guardrail_budget_contract
    standard_policy = Llm::OpenRouterWorkspacePolicy.resolve(workspace: 'production')
    sensitive_profile = Llm::OpenRouterRoutingProfile.for(
      feature: :captain_agent,
      model: 'openai/gpt-5.4-mini',
      privacy_profile: 'sensitive'
    )
    failures = []
    failures << 'budget guardrail must stay workspace-required' unless standard_policy.guardrails.dig(:budget, :status) == 'workspace_required'
    failures << 'sensitive profile must deny data collection' unless sensitive_profile.provider_preferences[:data_collection] == 'deny'
    failures << 'sensitive profile must suppress trace capture' if sensitive_profile.workspace_policy.trace_capture_allowed?

    {
      budget_guardrail: standard_policy.guardrails[:budget],
      sensitive_provider: sensitive_profile.provider_preferences,
      sensitive_trace_capture_allowed: sensitive_profile.workspace_policy.trace_capture_allowed?,
      expected: { budget: 'workspace_required', data_collection: 'deny', trace_capture_allowed: false },
      failures: failures
    }
  end

  def openrouter_feature_policy_contract
    captain = Llm::OpenRouterFeaturePolicy.for(feature: :assistant)
    editor = Llm::OpenRouterFeaturePolicy.for(feature: :editor)
    failures = []
    failures << 'Captain must allow datetime server tool' unless captain.allowed_server_tools.include?('openrouter:datetime')
    failures << 'Captain response healing plugin missing' unless captain.allowed_plugins.include?(RESPONSE_HEALING_PLUGIN_ID)
    failures << 'Captain context compression plugin missing' unless captain.allowed_plugins.include?('context-compression')
    failures << 'Editor must keep plugins blocked by default' if editor.allowed_plugins.present?
    failures << 'Editor low-cost tier must compile to flex' unless editor.compiled_service_tier == 'flex'
    failures << 'Prompt injection must be locally enforced' unless captain.guardrails.dig(:prompt_injection, :status) == 'local_enforced'
    failures << 'Extension registry must expose response recovery' unless extension_ids(captain).include?(RESPONSE_HEALING_PLUGIN_ID)
    failures << 'Deferred web search marker missing' unless deferred_extension_ids.include?('openrouter:web_search')

    {
      captain: captain.to_h,
      editor: editor.to_h,
      deferred_extensions: Llm::OpenRouterPluginPolicy.deferred_extensions,
      expected: {
        captain_server_tool: 'openrouter:datetime',
        captain_plugins: [RESPONSE_HEALING_PLUGIN_ID, 'context-compression'],
        editor_service_tier: 'flex',
        prompt_injection: 'local_enforced',
        deferred_extensions: ['openrouter:web_search']
      },
      failures: failures
    }
  end

  def extension_ids(policy)
    Array(policy.to_h[:extensions]).pluck(:id)
  end

  def deferred_extension_ids
    Llm::OpenRouterPluginPolicy.deferred_extensions.pluck(:id)
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
