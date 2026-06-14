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
    Llm::ModelEndpointEntry.delete_all if defined?(Llm::ModelEndpointEntry)
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
          'capabilities' => include('tool_calling', 'tool_choice', 'structured_output', 'reasoning'),
          'pricing' => include('prompt' => '0.000001', 'completion' => '0.000002'),
          'latency_ms' => 420.0,
          'throughput_tokens_per_second' => 88.5,
          'data_collection' => 'deny',
          'zdr' => true
        )
      )
      expect(Llm::ModelEndpointEntry.find_by!(provider_platform: 'openrouter', model_id: 'openai/gpt-4')).to have_attributes(
        endpoint_provider_name: 'OpenAI',
        endpoint_slug: 'openai/gpt-4',
        context_length: 8192,
        max_completion_tokens: 4096,
        latency_ms: 420,
        throughput_tokens_per_second: 88.5,
        data_collection: 'deny',
        zdr: true
      )
    end

    it 'refreshes endpoint metadata in rate-limited incremental batches' do
      stub_request(:get, endpoint_url)
        .to_return(status: 200, body: endpoint_response.to_json, headers: { 'Content-Type' => 'application/json' })
      stub_request(:get, anthropic_endpoint_url)
        .to_return(status: 200, body: anthropic_endpoint_response.to_json, headers: { 'Content-Type' => 'application/json' })

      first_metadata = described_class.refresh!(
        model_ids: %w[openai/gpt-4 anthropic/claude-sonnet-4],
        api_key: '[REDACTED]',
        limit: 1,
        throttle_seconds: 0
      )
      second_metadata = described_class.refresh!(
        model_ids: %w[openai/gpt-4 anthropic/claude-sonnet-4],
        api_key: '[REDACTED]',
        limit: 1,
        throttle_seconds: 0
      )

      expect(first_metadata).to include(
        refresh_status: 'incremental_pending',
        refreshed_model_ids: ['openai/gpt-4'],
        pending_model_count: 1
      )
      expect(first_metadata[:pending_model_ids]).to eq(['anthropic/claude-sonnet-4'])
      expect(second_metadata).to include(
        refresh_status: 'success',
        refreshed_model_ids: ['anthropic/claude-sonnet-4'],
        pending_model_count: 0
      )
      expect(described_class.endpoint_metadata('openai/gpt-4')).to include('providers' => ['OpenAI'])
      expect(described_class.endpoint_metadata('anthropic/claude-sonnet-4')).to include('providers' => ['Anthropic'])
    end

    it 'throttles between endpoint refresh requests' do
      stub_request(:get, endpoint_url)
        .to_return(status: 200, body: endpoint_response.to_json, headers: { 'Content-Type' => 'application/json' })
      stub_request(:get, anthropic_endpoint_url)
        .to_return(status: 200, body: anthropic_endpoint_response.to_json, headers: { 'Content-Type' => 'application/json' })

      expect(described_class).to receive(:sleep).with(0.01).once

      described_class.refresh!(
        model_ids: %w[openai/gpt-4 anthropic/claude-sonnet-4],
        api_key: '[REDACTED]',
        limit: 2,
        throttle_seconds: 0.01
      )
    end

    it 'stores refresh lifecycle metadata and endpoint changed/new/removed diff' do
      first_response = endpoint_response.deep_merge(
        data: {
          endpoints: [
            endpoint_response[:data][:endpoints].first,
            endpoint_response[:data][:endpoints].first.merge(provider_name: 'Acme', tag: 'acme/gpt-4')
          ]
        }
      )
      second_response = endpoint_response.deep_merge(
        data: {
          endpoints: [
            endpoint_response[:data][:endpoints].first.deep_merge(pricing: { prompt: '0.000003', completion: '0.000002' }),
            endpoint_response[:data][:endpoints].first.merge(provider_name: 'Azure OpenAI')
          ]
        }
      )
      stub_request(:get, endpoint_url)
        .to_return(status: 200, body: first_response.to_json, headers: { 'Content-Type' => 'application/json' })
        .then
        .to_return(status: 200, body: second_response.to_json, headers: { 'Content-Type' => 'application/json' })

      described_class.refresh!(model_ids: ['openai/gpt-4'], api_key: '[REDACTED]')
      metadata = described_class.refresh!(model_ids: ['openai/gpt-4'], api_key: '[REDACTED]')

      expect(metadata).to include(refresh_status: 'success')
      expect(metadata[:last_started_at]).to be_present
      expect(metadata[:last_finished_at]).to be_present
      expect(metadata[:last_refresh_diff]['new']).to include('openai/gpt-4|azure-openai|openai/gpt-4')
      expect(metadata[:last_refresh_diff]['changed']).to include('openai/gpt-4|openai|openai/gpt-4')
      expect(metadata[:last_refresh_diff]['removed']).to include('openai/gpt-4|acme|acme/gpt-4')
      expect(metadata[:last_refresh_diff]['provider_changed']).to include(
        include('model_id' => 'openai/gpt-4', 'added' => include('Azure OpenAI'), 'removed' => include('Acme'))
      )
      expect(metadata[:last_refresh_diff]['price_changed']).to include('openai/gpt-4|openai|openai/gpt-4')
      expect(described_class.metadata[:last_refresh_diff]['removed']).to include('openai/gpt-4|acme|acme/gpt-4')
      expect(described_class.metadata[:stale_endpoints]).to be >= 1
    end

    it 'does not report unchanged DB-backed endpoints as changed after cache reset' do
      tagless_response = endpoint_response.deep_merge(
        data: {
          endpoints: [endpoint_response[:data][:endpoints].first.except(:tag)]
        }
      )
      stub_request(:get, endpoint_url)
        .to_return(status: 200, body: tagless_response.to_json, headers: { 'Content-Type' => 'application/json' })
        .then
        .to_return(status: 200, body: tagless_response.to_json, headers: { 'Content-Type' => 'application/json' })

      described_class.refresh!(model_ids: ['openai/gpt-4'], api_key: '[REDACTED]')
      Rails.cache.clear
      described_class.instance_variable_set(:@last_endpoint_configs, nil)
      described_class.instance_variable_set(:@last_refreshed_at, nil)
      described_class.instance_variable_set(:@cached_endpoint_configs, nil)
      described_class.instance_variable_set(:@cached_endpoint_configs_refresh_marker, nil)
      described_class.instance_variable_set(:@cached_endpoint_configs_loaded, nil)
      metadata = described_class.refresh!(model_ids: ['openai/gpt-4'], api_key: '[REDACTED]')

      expect(metadata[:last_refresh_diff]['changed']).to be_empty
      expect(metadata[:last_refresh_diff]['price_changed']).to be_empty
      expect(metadata[:last_refresh_diff]['provider_changed']).to be_empty
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

    it 'uses endpoint rows before the legacy InstallationConfig payload' do
      Llm::ModelEndpointEntry.create!(
        provider_platform: 'openrouter',
        model_id: 'db/model',
        endpoint_slug: 'db-provider/db-model',
        endpoint_provider_name: 'DB Provider',
        endpoint_provider_key: 'db-provider',
        supported_parameters: %w[tools tool_choice response_format reasoning],
        capabilities: %w[streaming],
        context_length: 1000,
        max_prompt_tokens: 1000,
        max_completion_tokens: 200,
        pricing: { 'prompt' => '0.000001' },
        latency_ms: 100,
        throughput_tokens_per_second: 75.5,
        uptime_last_30m: 99.9,
        raw_payload: { 'tag' => 'db-provider/db-model', 'name' => 'DB Endpoint' },
        fetched_at: Time.current
      )
      InstallationConfig.create!(
        name: described_class::INSTALLATION_CONFIG_KEY,
        value: {
          'models' => {
            'legacy/model' => {
              'model_id' => 'legacy/model',
              'endpoint_count' => 1,
              'providers' => ['Legacy'],
              'endpoints' => [{ 'provider_name' => 'Legacy' }],
              'source' => 'installation_config'
            }
          }
        }
      )

      expect(described_class).not_to receive(:fetch_payload)
      expect(described_class.endpoint_metadata('db/model')).to include(
        'model_id' => 'db/model',
        'endpoint_count' => 1,
        'providers' => ['DB Provider'],
        'source' => 'openrouter_api'
      )
      expect(described_class.endpoint_metadata('legacy/model')).to be_nil
      expect(described_class.endpoints_for('db/model')).to include(
        include(
          'provider_name' => 'DB Provider',
          'supported_parameters' => %w[tools tool_choice response_format reasoning],
          'capabilities' => include('tool_calling', 'tool_choice', 'structured_output', 'reasoning'),
          'max_prompt_tokens' => 1000,
          'max_completion_tokens' => 200,
          'uptime_last_30m' => 99.9
        )
      )
    end

    it 'derives parameter capabilities from cached endpoint metadata with stale capabilities' do
      Rails.cache.write(
        described_class::CACHE_KEY,
        'cached/model' => {
          'model_id' => 'cached/model',
          'endpoint_count' => 1,
          'providers' => ['Cached Provider'],
          'source' => 'openrouter_api',
          'endpoints' => [
            {
              'provider_name' => 'Cached Provider',
              'supported_parameters' => %w[tools tool_choice response_format reasoning],
              'capabilities' => %w[streaming]
            }
          ]
        }
      )
      Rails.cache.write(described_class::LAST_REFRESH_AT_CACHE_KEY, '2026-05-20T09:41:29Z')

      expect(described_class.endpoints_for('cached/model')).to include(
        include('capabilities' => include('tool_calling', 'tool_choice', 'structured_output', 'reasoning'))
      )
    end

    it 'excludes stale endpoint rows from runtime diagnostics while preserving the row' do
      Llm::ModelEndpointEntry.create!(
        provider_platform: 'openrouter',
        model_id: 'db/model',
        endpoint_slug: 'current-endpoint',
        endpoint_provider_name: 'Current Provider',
        endpoint_provider_key: 'current-provider',
        capabilities: ['streaming'],
        fetched_at: Time.current
      )
      Llm::ModelEndpointEntry.create!(
        provider_platform: 'openrouter',
        model_id: 'db/model',
        endpoint_slug: 'stale-endpoint',
        endpoint_provider_name: 'Stale Provider',
        endpoint_provider_key: 'stale-provider',
        capabilities: ['streaming'],
        fetched_at: 1.hour.ago,
        stale_at: Time.current
      )

      expect(described_class.endpoint_metadata('db/model')).to include(
        'endpoint_count' => 1,
        'providers' => ['Current Provider']
      )
      expect(described_class.endpoints_for('db/model')).not_to include(include('provider_name' => 'Stale Provider'))
      expect(Llm::ModelEndpointEntry.find_by!(endpoint_slug: 'stale-endpoint').stale_at).to be_present
    end

    it 'reports stale running refresh status when endpoint refresh is abandoned' do
      InstallationConfig.create!(
        name: described_class::INSTALLATION_CONFIG_KEY,
        value: {
          'last_started_at' => 1.hour.ago.iso8601,
          'refresh_status' => 'running',
          'refresh_id' => 'stuck-endpoint-refresh'
        }
      )

      expect(described_class.metadata[:refresh_status]).to eq('stale_running')
    end

    it 'persists provider-distinct endpoints that share the same model tag' do
      shared_tag_response = endpoint_response.deep_merge(
        data: {
          endpoints: [
            endpoint_response[:data][:endpoints].first,
            endpoint_response[:data][:endpoints].first.merge(provider_name: 'Azure OpenAI')
          ]
        }
      )
      stub_request(:get, endpoint_url)
        .to_return(status: 200, body: shared_tag_response.to_json, headers: { 'Content-Type' => 'application/json' })

      described_class.refresh!(model_ids: ['openai/gpt-4'], api_key: '[REDACTED]')

      endpoint_providers = Llm::ModelEndpointEntry.where(provider_platform: 'openrouter', model_id: 'openai/gpt-4').pluck(:endpoint_provider_name)
      expect(endpoint_providers).to contain_exactly('Azure OpenAI', 'OpenAI')
      expect(described_class.endpoint_metadata('openai/gpt-4')).to include(
        'endpoint_count' => 2,
        'providers' => ['Azure OpenAI', 'OpenAI']
      )
    end

    it 'does not overwrite endpoint status when another refresh already holds the lock' do
      allow(described_class).to receive(:acquire_refresh_lock).and_return(false)

      expect do
        described_class.refresh!(model_ids: ['openai/gpt-4'], api_key: '[REDACTED]')
      end.to raise_error(described_class::RefreshAlreadyRunningError)
      expect(Rails.cache.read(described_class::LAST_REFRESH_ERROR_CACHE_KEY)).to be_nil
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
