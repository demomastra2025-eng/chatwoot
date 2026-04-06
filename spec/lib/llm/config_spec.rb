# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Config do
  before do
    described_class.reset!
  end

  describe '.provider_for_model' do
    it 'resolves provider through the product model registry' do
      expect(described_class.provider_for_model('gemini-3-pro')).to eq('gemini')
    end
  end

  describe '.api_key' do
    it 'reads provider-specific installation config' do
      upsert_installation_config('CAPTAIN_ANTHROPIC_API_KEY', 'anthropic-key')

      expect(described_class.api_key('anthropic')).to eq('anthropic-key')
    end
  end

  describe '.installation_default_model' do
    it 'prefers the provider-neutral default model setting' do
      upsert_installation_config('CAPTAIN_DEFAULT_MODEL', 'claude-sonnet-4.5')
      upsert_installation_config('CAPTAIN_OPEN_AI_MODEL', 'gpt-4.1-mini')

      expect(described_class.installation_default_model).to eq('claude-sonnet-4.5')
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
end
