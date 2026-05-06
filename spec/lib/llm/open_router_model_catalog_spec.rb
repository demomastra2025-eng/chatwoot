# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterModelCatalog do
  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }
  let(:api_url) { 'https://openrouter.ai/api/v1/models' }
  let(:api_response) do
    {
      data: [
        {
          id: 'openai/gpt-4',
          name: 'GPT-4 via OpenRouter',
          architecture: {
            input_modalities: %w[text image],
            output_modalities: ['text'],
            modality: 'text+image->text'
          },
          context_length: 8192,
          top_provider: { max_completion_tokens: 4096 },
          pricing: {
            prompt: '0.000001',
            completion: '0.000002',
            image: '0',
            request: '0'
          },
          supported_parameters: %w[temperature tools tool_choice response_format reasoning]
        },
        {
          id: 'image/provider',
          name: 'Image only',
          architecture: {
            input_modalities: ['text'],
            output_modalities: ['image'],
            modality: 'text->image'
          },
          pricing: {}
        }
      ]
    }
  end

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
    Rails.cache.clear
    described_class.instance_variable_set(:@last_model_configs, nil)
    described_class.instance_variable_set(:@last_refreshed_at, nil)
    described_class.instance_variable_set(:@last_refresh_error, nil)
  end

  describe '.model_configs' do
    it 'falls back to bundled OpenRouter models before the API has been refreshed' do
      models = described_class.model_configs

      expect(models).to include('anthropic/claude-3.5-haiku')
      expect(described_class.metadata).to include(
        source: 'config/llm_models.json',
        using_fallback: true
      )
    end

    it 'does not infer structured output for fallback models that only declare function calling' do
      capabilities = described_class.model_config('anthropic/claude-3.5-haiku')['capabilities']

      expect(capabilities).to include('tool_calling')
      expect(capabilities).not_to include('structured_output')
    end
  end

  describe '.refresh!' do
    it 'fetches OpenRouter models through the API and caches normalized chat metadata' do
      stub_request(:get, api_url)
        .with(headers: { 'Authorization' => 'Bearer [REDACTED]' })
        .to_return(status: 200, body: api_response.to_json, headers: { 'Content-Type' => 'application/json' })

      metadata = described_class.refresh!(api_key: '[REDACTED]')

      expect(metadata).to include(total_models: 1, chat_models: 1, source: 'openrouter_api', using_fallback: false)
      expect(metadata[:last_refreshed_at]).to be_present
      expect(described_class.model_config('openai/gpt-4')).to include(
        'provider' => 'openrouter',
        'display_name' => 'GPT-4 via OpenRouter',
        'type' => 'chat',
        'context_length' => 8192,
        'max_output_tokens' => 4096
      )
      expect(described_class.model_config('openai/gpt-4')['capabilities']).to include(
        'tool_calling', 'structured_output', 'reasoning', 'multimodal_input', 'image_input', 'text_output', 'streaming'
      )
      expect(described_class.model_config('image/provider')).to be_nil
    end

    it 'keeps freshly refreshed API models active when the cache store drops writes' do
      allow(cache_store).to receive(:write).and_return(false)
      allow(cache_store).to receive(:read).and_return(nil)
      stub_request(:get, api_url)
        .with(headers: { 'Authorization' => 'Bearer [REDACTED]' })
        .to_return(status: 200, body: api_response.to_json, headers: { 'Content-Type' => 'application/json' })

      metadata = described_class.refresh!(api_key: '[REDACTED]')

      expect(metadata).to include(total_models: 1, source: 'openrouter_api', using_fallback: false)
      expect(described_class.model_config('openai/gpt-4')).to include('source' => 'openrouter_api')
    end

    it 'raises when the OpenRouter API key is missing' do
      expect do
        described_class.refresh!(api_key: '')
      end.to raise_error(described_class::MissingApiKeyError, /not configured/)
    end

    it 'stores a sanitized error when the API request fails' do
      stub_request(:get, api_url).to_return(status: 401, body: '{"error":"bad token"}')

      expect do
        described_class.refresh!(api_key: '[REDACTED]')
      end.to raise_error(described_class::FetchError, /HTTP 401/)
      expect(Rails.cache.read(described_class::LAST_REFRESH_ERROR_CACHE_KEY)).to include('HTTP 401')
      expect(Rails.cache.read(described_class::LAST_REFRESH_ERROR_CACHE_KEY)).not_to include('SECRET_VALUE')
    end

    it 'redacts bearer tokens and API keys from generic refresh errors cached for UI metadata' do
      allow(described_class).to receive(:fetch_payload).and_raise(
        StandardError, 'request failed with Bearer sk-or-v1-secret and api_key=SECRET_VALUE'
      )

      expect do
        described_class.refresh!(api_key: '[REDACTED]')
      end.to raise_error(StandardError, /request failed/)

      cached_error = Rails.cache.read(described_class::LAST_REFRESH_ERROR_CACHE_KEY)
      expect(cached_error).to include('[REDACTED]')
      expect(cached_error).not_to include('sk-or-v1-secret')
      expect(cached_error).not_to include('SECRET_VALUE')
    end

    it 'keeps the last successful API catalog active after a failed refresh' do
      stub_request(:get, api_url)
        .to_return(status: 200, body: api_response.to_json, headers: { 'Content-Type' => 'application/json' })
        .then
        .to_return(status: 503, body: '{"error":"unavailable"}')

      described_class.refresh!(api_key: '[REDACTED]')

      expect do
        described_class.refresh!(api_key: '[REDACTED]')
      end.to raise_error(described_class::FetchError, /HTTP 503/)
      expect(described_class.model_configs.keys).to contain_exactly('openai/gpt-4')
      expect(described_class.metadata).to include(source: 'openrouter_api', using_fallback: false)
    end

    it 'raises a fetch error for invalid JSON without clearing the fallback catalog' do
      stub_request(:get, api_url).to_return(status: 200, body: '{invalid-json')

      expect do
        described_class.refresh!(api_key: '[REDACTED]')
      end.to raise_error(described_class::FetchError, /invalid JSON/)
      expect(described_class.model_configs).to include('anthropic/claude-3.5-haiku')
    end

    it 'raises a fetch error for malformed payloads without clearing the fallback catalog' do
      stub_request(:get, api_url).to_return(status: 200, body: { models: [] }.to_json)

      expect do
        described_class.refresh!(api_key: '[REDACTED]')
      end.to raise_error(described_class::FetchError, /missing data array/)
      expect(described_class.model_configs).to include('anthropic/claude-3.5-haiku')
    end
  end

  describe '.estimated_text_cost' do
    before do
      Rails.cache.write(
        described_class::CACHE_KEY,
        {
          'openai/gpt-4' => {
            'provider' => 'openrouter',
            'type' => 'chat',
            'pricing' => { 'prompt' => '0.000001', 'completion' => '0.000002' }
          }
        }
      )
    end

    it 'calculates cost from OpenRouter per-token pricing' do
      expect(described_class.estimated_text_cost('openai/gpt-4', input_tokens: 1000, output_tokens: 2000)).to eq(0.005)
    end
  end
end
