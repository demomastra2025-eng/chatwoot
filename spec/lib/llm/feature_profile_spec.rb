# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::FeatureProfile do
  it 'describes the Captain agent runtime contract' do
    profile = described_class.for(:assistant)

    expect(profile.feature_key).to eq('captain_agent')
    expect(profile.config_feature_key).to eq('assistant')
    expect(profile.required_capabilities).to include('text_input', 'text_output', 'tool_calling', 'structured_output')
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
    expect(copilot.required_capabilities).to include('tool_calling')
    expect(editor.cost_policy).to eq('speed_cost')
    expect(editor.required_capabilities).to include('text_input', 'text_output')
  end

  it 'returns canonical, config, and alias feature keys for accounting policy joins' do
    expect(described_class.equivalent_feature_keys(:assistant)).to contain_exactly('assistant', 'captain_agent', 'captain')
    expect(described_class.equivalent_feature_keys(:help_center_search)).to contain_exactly('help_center_search', 'embedding')
    expect(described_class.equivalent_feature_keys(:knowledge_rerank)).to eq(['knowledge_rerank'])
  end

  it 'rejects unsupported feature keys' do
    expect { described_class.for(:unknown_feature) }
      .to raise_error(ArgumentError, /Unsupported LLM feature/)
  end
end
