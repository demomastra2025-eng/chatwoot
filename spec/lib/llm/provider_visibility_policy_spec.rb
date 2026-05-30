# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ProviderVisibilityPolicy do
  describe '.visible_providers' do
    it 'exposes only OpenRouter in normal Captain settings' do
      expect(described_class.visible_providers.keys).to contain_exactly('openrouter')
    end

    it 'exposes only Gemini on voice surfaces' do
      expect(described_class.visible_providers(surface: :ai_voice).keys).to contain_exactly('gemini')
    end
  end

  describe '.hidden_reason' do
    it 'marks Gemini as voice-only in normal Captain settings' do
      expect(described_class.hidden_reason('gemini')).to eq('voice_only_provider')
    end

    it 'marks other direct providers as disabled in normal Captain settings' do
      expect(described_class.hidden_reason('openai')).to eq('direct_provider_disabled')
      expect(described_class.hidden_reason('anthropic')).to eq('direct_provider_disabled')
    end
  end
end
