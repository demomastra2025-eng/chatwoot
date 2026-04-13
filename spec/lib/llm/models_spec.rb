# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Models do
  describe '.capabilities_for' do
    it 'normalizes upstream registry capabilities to onelink capability names' do
      registry_info = instance_double('RubyLLM::Model::Info', capabilities: %w[function_calling vision], type: 'chat')
      allow(described_class).to receive(:registry_info_for).with('custom-model').and_return(registry_info)

      expect(described_class.capabilities_for('custom-model')).to include('tool_calling', 'multimodal_input')
    end
  end

  describe '.providers' do
    it 'loads providers from llm.yml' do
      expect(described_class.providers.keys).to include('openai', 'anthropic', 'gemini')
    end
  end

  describe '.provider_for' do
    it 'returns the configured provider for a model' do
      expect(described_class.provider_for('claude-sonnet-4-6')).to eq('anthropic')
    end
  end

  describe '.supports_thinking?' do
    it 'returns true for reasoning-capable models' do
      expect(described_class.supports_thinking?('gpt-5.4')).to be true
      expect(described_class.supports_thinking?('claude-sonnet-4-6')).to be true
      expect(described_class.supports_thinking?('gemini-2.5-pro')).to be true
    end

    it 'returns false for non-reasoning models' do
      expect(described_class.supports_thinking?('gpt-4.1-mini')).to be false
      expect(described_class.supports_thinking?('whisper-1')).to be false
    end
  end

  describe 'capability helpers' do
    it 'exposes structured output, tool calling, multimodal, streaming, embedding, and transcription support' do
      expect(described_class.supports_structured_output?('gpt-4.1-mini')).to be true
      expect(described_class.supports_tool_calling?('gpt-4.1-mini')).to be true
      expect(described_class.supports_multimodal_input?('gpt-4.1-mini')).to be true
      expect(described_class.supports_streaming?('gpt-4.1-mini')).to be true
      expect(described_class.supports_embedding?('text-embedding-3-small')).to be true
      expect(described_class.supports_transcription?('whisper-1')).to be true
    end
  end

  describe '.feature_config' do
    it 'includes provider and capabilities metadata for feature models' do
      config = described_class.feature_config(:assistant)
      claude = config[:models].find { |model| model[:id] == 'claude-sonnet-4-6' }

      expect(claude).to include(
        provider: 'anthropic',
        type: 'chat'
      )
      expect(claude[:capabilities]).to include('reasoning', 'structured_output', 'tool_calling')
    end
  end

  describe '.canonical_model_name' do
    it 'normalizes legacy Anthropic dotted aliases to canonical ids' do
      expect(described_class.canonical_model_name('claude-sonnet-4.6')).to eq('claude-sonnet-4-6')
      expect(described_class.canonical_model_name('claude-opus-4.6')).to eq('claude-opus-4-6')
    end
  end

  describe '.runtime_supported?' do
    it 'allows configured Anthropic ids even when the RubyLLM registry does not know them yet' do
      allow(described_class).to receive(:registry_known?).with('claude-sonnet-4-6').and_return(false)

      expect(described_class.runtime_supported?('claude-sonnet-4-6')).to be true
    end
  end

  describe 'pricing helpers' do
    it 'exposes configured credit multipliers' do
      expect(described_class.credit_multiplier_for('gpt-4.1-mini')).to eq(1)
      expect(described_class.credit_multiplier_for('gpt-5.4')).to eq(4)
    end

    it 'estimates text cost from registry pricing when available' do
      registry_model = instance_double(
        'RubyLLM::Model::Info',
        input_price_per_million: 0.5,
        output_price_per_million: 1.5
      )
      allow(described_class).to receive(:registry_model_for).with('custom-model').and_return(registry_model)

      expect(
        described_class.estimated_text_cost('custom-model', input_tokens: 1_000_000, output_tokens: 500_000)
      ).to eq(1.25)
    end
  end
end
