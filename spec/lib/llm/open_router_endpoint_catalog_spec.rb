# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterEndpointCatalog do
  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }
  let(:endpoint_url) { 'https://openrouter.ai/api/v1/models/openai/gpt-4/endpoints' }
  let(:anthropic_endpoint_url) { 'https://openrouter.ai/api/v1/models/anthropic/claude-sonnet-4/endpoints' }
  let(:endpoint_response) do
    {
      data: {
        id: 'openai/gpt-4',
        endpoints: [
          {
            name: 'OpenAI | GPT-4',
            provider_name: 'OpenAI',
            tag: 'openai/gpt-4',
            context_length: 8192,
            max_completion_tokens: 4096,
            supported_parameters: %w[temperature tools tool_choice response_format reasoning],
            pricing: {
              prompt: '0.000001',
              completion: '0.000002'
            },
            latency_ms: 420,
            throughput_tokens_per_second: 88.5,
            data_collection: 'deny',
            zdr: true
          }
        ]
      }
    }
  end
  let(:anthropic_endpoint_response) do
    {
      data: {
        id: 'anthropic/claude-sonnet-4',
        endpoints: [
          {
            name: 'Anthropic | Claude Sonnet 4',
            provider_name: 'Anthropic',
            tag: 'anthropic/claude-sonnet-4',
            context_length: 200_000,
            supported_parameters: %w[tools response_format]
          }
        ]
      }
    }
  end

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
    Rails.cache.clear
    described_class.instance_variable_set(:@last_endpoint_configs, nil)
    described_class.instance_variable_set(:@last_refreshed_at, nil)
    described_class.instance_variable_set(:@last_refresh_error, nil)
    described_class.instance_variable_set(:@cached_endpoint_configs, nil)
    described_class.instance_variable_set(:@cached_endpoint_configs_refresh_marker, nil)
    described_class.instance_variable_set(:@cached_endpoint_configs_loaded, nil)
    InstallationConfig.where(name: described_class::INSTALLATION_CONFIG_KEY).delete_all
  end

  describe '.refresh!' do
    it 'fetches and persists endpoint metadata for selected OpenRouter models' do
      stub_request(:get, endpoint_url)
        .with(headers: { 'Authorization' => 'Bearer [REDACTED]' })
        .to_return(status: 200, body: endpoint_response.to_json, headers: { 'Content-Type' => 'application/json' })

      metadata = described_class.refresh!(model_ids: ['openai/gpt-4'], api_key: '[REDACTED]')

      expect(metadata).to include(total_models: 1, total_endpoints: 1, source: 'openrouter_api')
      expect(metadata[:providers]).to eq(['OpenAI'])
      expect(described_class.endpoint_metadata('openai/gpt-4')).to include(
        'model_id' => 'openai/gpt-4',
        'endpoint_count' => 1,
        'providers' => ['OpenAI'],
        'source' => 'openrouter_api'
      )
      expect(described_class.endpoints_for('openai/gpt-4')).to include(
        include(
          'provider_name' => 'OpenAI',
          'context_length' => 8192,
          'max_output_tokens' => 4096,
          'supported_parameters' => include('tools', 'response_format'),
          'capabilities' => include('tool_calling', 'structured_output', 'reasoning'),
          'pricing' => include('prompt' => '0.000001', 'completion' => '0.000002'),
          'latency_ms' => 420.0,
          'throughput_tokens_per_second' => 88.5,
          'data_collection' => 'deny',
          'zdr' => true
        )
      )
    end

    it 'keeps endpoint metadata after cache and process memory are reset' do
      stub_request(:get, endpoint_url)
        .to_return(status: 200, body: endpoint_response.to_json, headers: { 'Content-Type' => 'application/json' })

      described_class.refresh!(model_ids: ['openai/gpt-4'], api_key: '[REDACTED]')
      Rails.cache.clear
      described_class.instance_variable_set(:@last_endpoint_configs, nil)
      described_class.instance_variable_set(:@last_refreshed_at, nil)
      described_class.instance_variable_set(:@cached_endpoint_configs, nil)
      described_class.instance_variable_set(:@cached_endpoint_configs_refresh_marker, nil)
      described_class.instance_variable_set(:@cached_endpoint_configs_loaded, nil)

      expect(described_class.endpoint_metadata('openai/gpt-4')).to include('source' => 'openrouter_api')
      expect(described_class.metadata).to include(source: 'openrouter_api', total_endpoints: 1)
    end

    it 'raises when the OpenRouter API key is missing' do
      expect do
        described_class.refresh!(model_ids: ['openai/gpt-4'], api_key: '')
      end.to raise_error(described_class::MissingApiKeyError, /not configured/)
    end

    it 'stores a sanitized error and keeps the last successful endpoint catalog when refresh fails' do
      stub_request(:get, endpoint_url)
        .to_return(status: 200, body: endpoint_response.to_json, headers: { 'Content-Type' => 'application/json' })
        .then
        .to_return(status: 503, body: '{"error":"Bearer SECRET_VALUE unavailable"}')

      described_class.refresh!(model_ids: ['openai/gpt-4'], api_key: '[REDACTED]')

      expect do
        described_class.refresh!(model_ids: ['openai/gpt-4'], api_key: '[REDACTED]')
      end.to raise_error(described_class::FetchError, /failed for 1 model/)
      expect(described_class.endpoint_metadata('openai/gpt-4')).to include('source' => 'openrouter_api')
      expect(Rails.cache.read(described_class::LAST_REFRESH_ERROR_CACHE_KEY)).not_to include('SECRET_VALUE')
    end

    it 'retains stale endpoint metadata for models that fail during a partial refresh' do
      refreshed_openai_response = endpoint_response.deep_merge(
        data: { endpoints: [{ provider_name: 'OpenAI', context_length: 16_384 }] }
      )
      stub_request(:get, endpoint_url)
        .to_return(status: 200, body: endpoint_response.to_json, headers: { 'Content-Type' => 'application/json' })
        .then
        .to_return(status: 200, body: refreshed_openai_response.to_json, headers: { 'Content-Type' => 'application/json' })
      stub_request(:get, anthropic_endpoint_url)
        .to_return(status: 200, body: anthropic_endpoint_response.to_json, headers: { 'Content-Type' => 'application/json' })
        .then
        .to_timeout

      described_class.refresh!(model_ids: %w[openai/gpt-4 anthropic/claude-sonnet-4], api_key: '[REDACTED]')
      metadata = described_class.refresh!(model_ids: %w[openai/gpt-4 anthropic/claude-sonnet-4], api_key: '[REDACTED]')

      expect(metadata[:last_refresh_error]['anthropic/claude-sonnet-4']).to match(/request failed/i)
      expect(described_class.endpoint_metadata('openai/gpt-4')).to include('endpoint_count' => 1)
      expect(described_class.endpoint_metadata('anthropic/claude-sonnet-4')).to include(
        'endpoint_count' => 1,
        'providers' => ['Anthropic']
      )
      expect(Rails.cache.read(described_class::LAST_REFRESH_ERROR_CACHE_KEY).to_s).not_to include('SECRET_VALUE')
    end

    it 'raises a fetch error for malformed endpoint payloads without clearing stale metadata' do
      stub_request(:get, endpoint_url)
        .to_return(status: 200, body: endpoint_response.to_json, headers: { 'Content-Type' => 'application/json' })
        .then
        .to_return(status: 200, body: { data: { id: 'openai/gpt-4' } }.to_json)

      described_class.refresh!(model_ids: ['openai/gpt-4'], api_key: '[REDACTED]')

      expect do
        described_class.refresh!(model_ids: ['openai/gpt-4'], api_key: '[REDACTED]')
      end.to raise_error(described_class::FetchError, /missing endpoints array/)
      expect(described_class.endpoint_metadata('openai/gpt-4')).to include('endpoint_count' => 1)
    end
  end
end
