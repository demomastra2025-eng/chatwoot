# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Config do
  before do
    described_class.reset!
  end

  describe 'defaults' do
    it 'uses gpt-5.4-mini as the global fallback model' do
      expect(described_class::DEFAULT_MODEL).to eq('gpt-5.4-mini')
    end
  end

  describe '.provider_for_model' do
    it 'resolves provider through the product model registry' do
      expect(described_class.provider_for_model('gemini-2.5-pro')).to eq('gemini')
    end

    it 'infers OpenRouter for provider-prefixed model ids discovered from OpenRouter' do
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-4o' => { 'provider' => 'openrouter', 'type' => 'chat', 'capabilities' => %w[streaming] }
      )

      expect(described_class.provider_for_model('openai/gpt-4o')).to eq('openrouter')
    end
  end

  describe '.api_key' do
    it 'reads provider-specific installation config' do
      upsert_installation_config('CAPTAIN_ANTHROPIC_API_KEY', 'anthropic-key')

      expect(described_class.api_key('anthropic')).to eq('anthropic-key')
    end

    it 'reads the OpenRouter installation config' do
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', '[REDACTED]')

      expect(described_class.api_key('openrouter')).to eq('[REDACTED]')
    end
  end

  describe '.api_base' do
    it 'uses the default OpenRouter API base when no custom endpoint is configured' do
      expect(described_class.api_base('openrouter')).to eq('https://openrouter.ai/api/v1')
    end

    it 'keeps custom OpenRouter API base unchanged except for trailing slash' do
      upsert_installation_config('CAPTAIN_OPENROUTER_ENDPOINT', 'https://openrouter.example/api/v1/')

      expect(described_class.api_base('openrouter')).to eq('https://openrouter.example/api/v1')
    end
  end

  describe '.installation_default_model' do
    it 'prefers the provider-neutral default model setting' do
      upsert_installation_config('CAPTAIN_DEFAULT_MODEL', 'claude-sonnet-4-6')
      upsert_installation_config('CAPTAIN_OPEN_AI_MODEL', 'gpt-4.1-mini')

      expect(described_class.installation_default_model).to eq('claude-sonnet-4-6')
    end

    it 'falls back to the legacy OpenAI model setting when needed' do
      upsert_installation_config('CAPTAIN_OPEN_AI_MODEL', 'gpt-4.1-mini')

      expect(described_class.installation_default_model).to eq('gpt-4.1-mini')
    end
  end

  describe '.context' do
    it 'configures the selected provider in an isolated RubyLLM context' do
      yielded_config = Class.new do
        attr_accessor :gemini_api_key, :gemini_api_base
      end.new
      allow(yielded_config).to receive(:gemini_api_key=)
      allow(yielded_config).to receive(:gemini_api_base=)

      expect(RubyLLM).to receive(:context).and_yield(yielded_config)
      expect(yielded_config).to receive(:gemini_api_key=).with('gemini-key')
      expect(yielded_config).to receive(:gemini_api_base=).with('https://example.com')

      described_class.context(
        provider: 'gemini',
        api_key: 'gemini-key',
        api_base: 'https://example.com'
      )
    end
  end

  describe '.model_for' do
    it 'normalizes legacy Anthropic aliases from installation config' do
      upsert_installation_config('CAPTAIN_DEFAULT_MODEL', 'claude-sonnet-4.6')

      expect(described_class.model_for(feature: 'assistant')).to eq('claude-sonnet-4-6')
    end
  end
end
