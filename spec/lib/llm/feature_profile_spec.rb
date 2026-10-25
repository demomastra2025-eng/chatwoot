# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::FeatureProfile do
  it 'describes the Captain agent runtime contract' do
    profile = described_class.for(:assistant)

    expect(profile.feature_key).to eq('captain_agent')
    expect(profile.config_feature_key).to eq('assistant')
    expect(profile.required_capabilities).to include('text_input', 'text_output', 'tool_calling', 'tool_choice', 'structured_output')
    expect(profile.timeout_seconds).to eq(60)
    expect(profile.max_retries).to eq(2)
    expect(profile.streaming?).to be(false)
    expect(profile.native_endpoint).to be_nil
    expect(profile.structured_output?).to be(true)
    expect(profile.response_healing?).to be(true)
    expect(profile.fallback_strategy).to eq('short_reliable')
  end

  it 'marks audio transcription, embedding, and rerank as native endpoint features' do
    transcription = described_class.for(:audio_transcription)
    embedding = described_class.for(:help_center_search)
    rerank = described_class.for(:knowledge_rerank)

    expect(transcription.feature_key).to eq('audio_transcription')
    expect(transcription.config_feature_key).to eq('audio_transcription')
    expect(transcription.native_endpoint).to eq('/audio/transcriptions')
    expect(transcription.required_capabilities).to include('audio_input', 'transcription')
    expect(transcription.structured_output?).to be(false)
    expect(transcription.response_healing?).to be(false)

    expect(embedding.feature_key).to eq('embedding')
    expect(embedding.config_feature_key).to eq('help_center_search')
    expect(embedding.native_endpoint).to eq('/embeddings')
    expect(embedding.required_capabilities).to include('embedding')

    expect(rerank.feature_key).to eq('knowledge_rerank')
    expect(rerank.config_feature_key).to eq('knowledge_rerank')
    expect(rerank.native_endpoint).to eq('/rerank')
    expect(rerank.required_capabilities).to include('rerank')
  end

  it 'keeps latency-first Copilot policy separate from background features' do
    copilot = described_class.for(:copilot)
    editor = described_class.for(:editor)

    expect(copilot.cost_policy).to eq('latency_first')
    expect(copilot.required_capabilities).to include('tool_calling', 'tool_choice')
    expect(editor.cost_policy).to eq('speed_cost')
    expect(editor.required_capabilities).to include('text_input', 'text_output')
  end

  it 'returns canonical, config, and alias feature keys for accounting policy joins' do
    expect(described_class.equivalent_feature_keys(:assistant)).to contain_exactly('assistant', 'captain_agent', 'captain')
    expect(described_class.equivalent_feature_keys(:help_center_search)).to contain_exactly('help_center_search', 'embedding')
    expect(described_class.equivalent_feature_keys(:knowledge_rerank)).to eq(['knowledge_rerank'])
  end

  it 'registers the decisions of a patient turn as short native decision features' do
    %i[agent_routing fact_check_gate inbound_triage].each do |feature|
      profile = described_class.for(feature)

      expect(profile).to have_attributes(
        feature_key: feature.to_s, config_feature_key: feature.to_s, native_endpoint: '/alpha/decisions',
        required_capabilities: %w[decision_classification], timeout_seconds: 2, max_retries: 0, reasoning_policy: 'disabled'
      )
      expect(profile).to be_decisions.and be_strict_timeout
    end
  end

  it 'derives the decision features from the profiles instead of a fixed list' do
    expect(described_class.decision_feature_keys).to contain_exactly(
      'outcome_classification', 'language_detection', 'custom_guardrail', 'agent_routing', 'fact_check_gate', 'inbound_triage'
    )
    expect(described_class.decision_feature?(:agent_routing)).to be(true)
    expect(described_class.decision_feature?('custom_guardrail')).to be(true)
    %i[assistant captain_agent copilot moderation embedding unknown_feature].each do |feature|
      expect(described_class.decision_feature?(feature)).to be(false)
    end
    expect(described_class.decision_feature?(nil)).to be(false)
    expect(described_class.for(:custom_guardrail)).not_to be_strict_timeout
  end

  it 'gives the background decision features one fallback decision model each, and the turn decisions none (their chain falls back)' do
    expect(described_class.for(:custom_guardrail).decision_fallback_models).to eq(%w[openai/gpt-6-luna-decisions])
    expect(described_class.for(:language_detection).decision_fallback_models).to eq(%w[respan/span-02])
    expect(described_class.for(:outcome_classification).decision_fallback_models).to eq(%w[microsoft/microsoft-decision-1])
    %i[agent_routing fact_check_gate inbound_triage assistant].each do |feature|
      expect(described_class.for(feature).decision_fallback_models).to eq([])
    end
  end

  it 'registers the escalation of the router and the council split as structured chat features, not decision features' do
    escalation = described_class.for(:agent_routing_escalation)
    split = described_class.for(:council_split)

    expect(escalation).to have_attributes(timeout_seconds: 10, max_retries: 0, reasoning_policy: 'platform')
    expect(split).to have_attributes(timeout_seconds: 4, max_retries: 0, reasoning_policy: 'disabled')
    expect([escalation, split]).to all(be_structured_output)
    expect([escalation, split].map(&:decisions?)).to eq([false, false])
  end

  it 'rejects unsupported feature keys' do
    expect { described_class.for(:unknown_feature) }
      .to raise_error(ArgumentError, /Unsupported LLM feature/)
  end
end
