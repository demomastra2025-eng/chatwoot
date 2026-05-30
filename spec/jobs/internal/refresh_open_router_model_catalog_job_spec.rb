# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Internal::RefreshOpenRouterModelCatalogJob do
  describe '#perform' do
    it 'skips refresh when the global OpenRouter key is not configured' do
      allow(Llm::Config).to receive(:installation_provider_available?).with('openrouter').and_return(false)
      expect(Llm::ModelRegistryService).not_to receive(:refresh_openrouter!)

      described_class.perform_now
    end

    it 'refreshes the shared OpenRouter model catalog when the global key is configured' do
      allow(Llm::Config).to receive(:installation_provider_available?).with('openrouter').and_return(true)
      expect(Llm::ModelRegistryService).to receive(:refresh_openrouter!).and_return(
        total_models: 10,
        source: 'openrouter_api',
        last_refreshed_at: '2026-05-29T12:00:00Z'
      )

      described_class.perform_now
    end

    it 'logs refresh failures without raising to keep the last successful catalog active' do
      allow(Llm::Config).to receive(:installation_provider_available?).with('openrouter').and_return(true)
      allow(Llm::ModelRegistryService).to receive(:refresh_openrouter!).and_raise(StandardError, 'upstream failed')

      expect { described_class.perform_now }.not_to raise_error
    end
  end
end
