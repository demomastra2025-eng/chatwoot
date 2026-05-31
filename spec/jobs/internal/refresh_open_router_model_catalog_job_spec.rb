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
      allow(Llm::OpenRouterKeyHealth).to receive(:refresh!).and_return(status: 'valid')
      expect(Llm::ModelRegistryService).to receive(:refresh_openrouter!).and_return(
        total_models: 10,
        source: 'openrouter_api',
        last_refreshed_at: '2026-05-29T12:00:00Z',
        endpoints: { pending_model_count: 0 }
      )

      described_class.perform_now
    end

    it 'skips refresh when the OpenRouter key health blocks catalog refresh' do
      allow(Llm::Config).to receive(:installation_provider_available?).with('openrouter').and_return(true)
      allow(Llm::OpenRouterKeyHealth).to receive(:refresh!).and_return(status: 'invalid')
      expect(Llm::ModelRegistryService).not_to receive(:refresh_openrouter!)
      expect(Llm::ModelRegistryService).not_to receive(:refresh_openrouter_endpoints!)

      described_class.perform_now
    end

    it 'continues endpoint refresh in follow-up jobs when the endpoint catalog has pending models' do
      allow(Llm::Config).to receive(:installation_provider_available?).with('openrouter').and_return(true)
      allow(Llm::OpenRouterKeyHealth).to receive(:refresh!).and_return(status: 'valid')
      allow(Llm::ModelRegistryService).to receive(:refresh_openrouter!).and_return(
        total_models: 10,
        source: 'openrouter_api',
        last_refreshed_at: '2026-05-29T12:00:00Z',
        endpoints: { pending_model_count: 7 }
      )
      continuation = instance_double(ActiveJob::ConfiguredJob)

      expect(described_class).to receive(:set).with(wait: described_class::ENDPOINT_CONTINUATION_DELAY).and_return(continuation)
      expect(continuation).to receive(:perform_later).with(endpoint_only: true)

      described_class.perform_now
    end

    it 'refreshes only the next endpoint batch for continuation jobs' do
      allow(Llm::Config).to receive(:installation_provider_available?).with('openrouter').and_return(true)
      allow(Llm::OpenRouterKeyHealth).to receive(:refresh!).and_return(status: 'valid')
      expect(Llm::ModelRegistryService).to receive(:refresh_openrouter_endpoints!).and_return(pending_model_count: 0)
      expect(Llm::ModelRegistryService).not_to receive(:refresh_openrouter!)

      described_class.perform_now(endpoint_only: true)
    end

    it 'logs refresh failures without raising to keep the last successful catalog active' do
      allow(Llm::Config).to receive(:installation_provider_available?).with('openrouter').and_return(true)
      allow(Llm::OpenRouterKeyHealth).to receive(:refresh!).and_return(status: 'valid')
      allow(Llm::ModelRegistryService).to receive(:refresh_openrouter!).and_raise(StandardError, 'upstream failed')

      expect { described_class.perform_now }.not_to raise_error
    end
  end
end
