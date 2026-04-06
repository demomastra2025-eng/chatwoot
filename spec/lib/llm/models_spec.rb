# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Models do
  describe '.providers' do
    it 'loads providers from llm.yml' do
      expect(described_class.providers.keys).to include('openai', 'anthropic', 'gemini')
    end
  end

  describe '.provider_for' do
    it 'returns the configured provider for a model' do
      expect(described_class.provider_for('claude-sonnet-4.5')).to eq('anthropic')
    end
  end

  describe '.supports_thinking?' do
    it 'returns true for reasoning-capable models' do
      expect(described_class.supports_thinking?('gpt-5.1')).to be true
      expect(described_class.supports_thinking?('claude-sonnet-4.5')).to be true
    end

    it 'returns false for non-reasoning models' do
      expect(described_class.supports_thinking?('gpt-4.1-mini')).to be false
      expect(described_class.supports_thinking?('whisper-1')).to be false
    end
  end

  describe '.feature_config' do
    it 'includes provider and capabilities metadata for feature models' do
      config = described_class.feature_config(:assistant)
      claude = config[:models].find { |model| model[:id] == 'claude-sonnet-4.5' }

      expect(claude).to include(
        provider: 'anthropic',
        type: 'chat'
      )
      expect(claude[:capabilities]).to include('reasoning')
    end
  end
end
