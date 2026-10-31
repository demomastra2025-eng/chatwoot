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

  it 'compiles provider.zdr = true into standard OpenRouterRoutingProfile requests' do
    routing = Llm::OpenRouterRoutingProfile.for(
      feature: 'captain_agent',
      model: 'openai/gpt-6-luna'
    )
    expect(routing.provider_preferences[:zdr]).to be(true)
    expect(routing.provider_preferences[:data_collection]).to eq('deny')
  end

  it 'uses ZDR-compatible Mercury Decide and Microsoft/Perplexity fallbacks for decision features' do
    expect(Llm::Models.configured_default_model_for('language_detection')).to eq('inception/mercury-decide')
    expect(Llm::FeatureProfile.for(:language_detection).decision_fallback_models).to eq(%w[microsoft/microsoft-decision-1])
    expect(Llm::FeatureProfile.for(:custom_guardrail).decision_fallback_models).to eq(%w[inception/mercury-decide])
    expect(Llm::DecisionChain::DEFAULT_MODELS).to eq(
      %w[inception/mercury-decide microsoft/microsoft-decision-1 perplexity/pplx-decider-v1.2]
    )
  end
end
