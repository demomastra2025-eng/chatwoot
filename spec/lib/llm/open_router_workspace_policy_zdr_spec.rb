# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterWorkspacePolicy do
  it 'enforces provider zdr: true and data_collection: deny across all privacy profiles' do
    %w[standard sensitive zdr_required].each do |profile|
      policy = described_class.resolve(privacy_profile: profile)
      expect(policy.provider_preferences[:zdr]).to be(true)
      expect(policy.provider_preferences[:data_collection]).to eq('deny')
      expect(policy.zdr_enforced?).to be(true)
    end

    expect(described_class.resolve(privacy_profile: 'standard').zdr_required?).to be(false)
    expect(described_class.resolve(privacy_profile: 'standard').provider_preferences[:allow_fallbacks]).to be(true)
    expect(described_class.resolve(privacy_profile: 'zdr_required').zdr_required?).to be(true)
    expect(described_class.resolve(privacy_profile: 'zdr_required').provider_preferences[:allow_fallbacks]).to be(false)
  end

  it 'compiles provider.zdr = true into chat and ZDR-capable decision routing profiles' do
    chat_routing = Llm::OpenRouterRoutingProfile.for(feature: 'captain_agent', model: 'openai/gpt-6-luna')
    zdr_decision_routing = Llm::OpenRouterRoutingProfile.for(feature: 'agent_routing', model: 'perplexity/pplx-decider-v1.2')

    expect(chat_routing.provider_preferences).to include(zdr: true, data_collection: 'deny')
    expect(zdr_decision_routing.provider_preferences).to include(zdr: true, data_collection: 'deny')
  end

  it 'uses the approved decision defaults and fallback chains' do
    expect(Llm::Models.configured_default_model_for('language_detection')).to eq('perplexity/pplx-decider-v1.2')
    expect(Llm::FeatureProfile.for(:language_detection).decision_fallback_models).to eq(%w[liquid/d1 respan/span-02])
    expect(Llm::FeatureProfile.for(:custom_guardrail).decision_fallback_models).to eq(%w[liquid/d1 typesafe/jev-1.14])
    expect(Llm::DecisionChain::DEFAULT_MODELS).to eq(
      %w[perplexity/pplx-decider-v1.2 liquid/d1 typesafe/jev-1.14]
    )
  end

  it 'omits zdr: true on non-ZDR decision endpoints under standard profile so OpenRouter never returns HTTP 404' do
    luna_dec = Llm::OpenRouterRoutingProfile.for(feature: 'language_detection', model: 'openai/gpt-6-luna-decisions')
    span_dec = Llm::OpenRouterRoutingProfile.for(feature: 'language_detection', model: 'respan/span-02')

    expect(luna_dec.provider_preferences[:data_collection]).to eq('deny')
    expect(luna_dec.provider_preferences).not_to have_key(:zdr)
    expect(span_dec.provider_preferences[:data_collection]).to eq('deny')
    expect(span_dec.provider_preferences).not_to have_key(:zdr)
  end
end
