# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterModelCatalog do
  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }
  let(:api_url) { 'https://openrouter.ai/api/v1/models?output_modalities=all' }
  let(:embedding_api_url) { 'https://openrouter.ai/api/v1/embeddings/models' }
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
          top_provider: {
            max_completion_tokens: 4096,
            latency: 420,
            throughput: 87.5
          },
          pricing: {
            prompt: '0.000001',
            completion: '0.000002',
            input_cache_read: '0.0000001',
            input_cache_write: '0.0000005',
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
        },
        {
          id: 'cohere/rerank-v3.5',
          name: 'Cohere Rerank 3.5',
          type: 'rerank',
          architecture: {
            input_modalities: ['text'],
            output_modalities: ['rerank'],
            modality: 'text->rerank'
          },
          context_length: 4096,
          pricing: {
            prompt: '0.0000002'
          }
        }
      ]
    }
  end
  let(:embedding_api_response) do
    {
      data: [
        {
          id: 'openai/text-embedding-3-small',
          name: 'Text Embedding 3 Small',
          architecture: {
            input_modalities: ['text'],
            output_modalities: ['embeddings'],
            modality: 'text->embeddings'
          },
          context_length: 8192,
          pricing: {
            prompt: '0.00000002',
            completion: '0',
            image: '0',
            request: '0'
          },
          dimensions: 1536,
          supported_parameters: []
        },
        {
          id: 'baai/bge-m3',
          name: 'BGE M3',
          architecture: {
            input_modalities: ['text'],
            output_modalities: ['embeddings'],
            modality: 'text->embeddings'
          },
          context_length: 8192,
          pricing: {
            prompt: '0.00000001',
            completion: '0'
          }
        }
      ]
    }
  end

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
    stub_request(:get, embedding_api_url)
      .to_return(status: 200, body: { data: [] }.to_json, headers: { 'Content-Type' => 'application/json' })
    Rails.cache.clear
    described_class.instance_variable_set(:@last_model_configs, nil)
    described_class.instance_variable_set(:@last_refreshed_at, nil)
    described_class.instance_variable_set(:@last_refresh_error, nil)
    described_class.instance_variable_set(:@cached_model_configs, nil)
    described_class.instance_variable_set(:@cached_model_configs_refresh_marker, nil)
    described_class.instance_variable_set(:@cached_model_configs_loaded, nil)
    InstallationConfig.where(name: described_class::INSTALLATION_CONFIG_KEY).delete_all
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

    it 'reuses normalized cached API models across repeated reads for the same refresh marker' do
      Rails.cache.write(
        described_class::CACHE_KEY,
        'openai/gpt-4' => { provider: 'openrouter', type: 'chat', capabilities: %w[streaming] }
      )
      Rails.cache.write(described_class::LAST_REFRESH_AT_CACHE_KEY, '2026-05-20T09:41:29Z')

      expect(Rails.cache).to receive(:read).with(described_class::LAST_REFRESH_AT_CACHE_KEY).twice.and_call_original
      expect(Rails.cache).to receive(:read).with(described_class::CACHE_KEY).once.and_call_original

      2.times do
        expect(described_class.model_configs).to include(
          'openai/gpt-4' => include('provider' => 'openrouter')
        )
      end
    end

    it 'uses a thread-local snapshot to avoid repeated cache reads while building one payload' do
      Rails.cache.write(
        described_class::CACHE_KEY,
        'openai/gpt-4' => { provider: 'openrouter', type: 'chat', capabilities: %w[streaming] }
      )
      Rails.cache.write(described_class::LAST_REFRESH_AT_CACHE_KEY, '2026-05-20T09:41:29Z')

      expect(Rails.cache).to receive(:read).with(described_class::LAST_REFRESH_AT_CACHE_KEY).once.and_call_original
      expect(Rails.cache).to receive(:read).with(described_class::CACHE_KEY).once.and_call_original

      described_class.with_model_configs_snapshot do
        2.times do
          expect(described_class.model_config('openai/gpt-4')).to include('provider' => 'openrouter')
          expect(described_class.model_ids).to include('openai/gpt-4')
        end
      end
    end
  end

  describe '.refresh!' do
    it 'fetches OpenRouter models through the API and caches normalized chat metadata' do
      stub_request(:get, api_url)
        .with(headers: { 'Authorization' => 'Bearer [REDACTED]' })
        .to_return(status: 200, body: api_response.to_json, headers: { 'Content-Type' => 'application/json' })
      stub_request(:get, embedding_api_url)
        .with(headers: { 'Authorization' => 'Bearer [REDACTED]' })
        .to_return(status: 200, body: embedding_api_response.to_json, headers: { 'Content-Type' => 'application/json' })

      metadata = described_class.refresh!(api_key: '[REDACTED]')

      expect(metadata).to include(total_models: 3, chat_models: 1, embedding_models: 1, rerank_models: 1, source: 'openrouter_api',
                                  using_fallback: false)
      expect(metadata[:last_refreshed_at]).to match(/\.\d{6}/)
      expect(described_class.model_config('openai/gpt-4')).to include(
        'provider' => 'openrouter',
        'display_name' => 'GPT-4 via OpenRouter',
        'type' => 'chat',
        'input_modalities' => %w[text image],
        'output_modalities' => ['text'],
        'context_length' => 8192,
        'max_output_tokens' => 4096,
        'latency_ms' => 420.0,
        'throughput_tokens_per_second' => 87.5,
        'pricing' => include(
          'prompt' => '0.000001',
          'completion' => '0.000002',
          'input_cache_read' => '0.0000001',
          'input_cache_write' => '0.0000005'
        )
      )
      expect(described_class.model_config('openai/gpt-4')['capabilities']).to include(
        'tool_calling', 'structured_output', 'reasoning', 'multimodal_input', 'image_input', 'text_output', 'streaming'
      )
      expect(described_class.model_config('openai/text-embedding-3-small')).to include(
        'provider' => 'openrouter',
        'display_name' => 'Text Embedding 3 Small',
        'type' => 'embedding',
        'input_modalities' => ['text'],
        'output_modalities' => ['embeddings'],
        'context_length' => 8192,
        'embedding_dimensions' => 1536,
        'requested_embedding_dimensions' => 1536,
        'pricing' => include('prompt' => '0.00000002')
      )
      expect(described_class.model_config('openai/text-embedding-3-small')['capabilities']).to include('embedding', 'text_input')
      expect(described_class.model_config('baai/bge-m3')).to be_nil
      expect(described_class.model_config('cohere/rerank-v3.5')).to include(
        'provider' => 'openrouter',
        'display_name' => 'Cohere Rerank 3.5',
        'type' => 'rerank',
        'input_modalities' => ['text'],
        'output_modalities' => ['rerank'],
        'context_length' => 4096,
        'pricing' => include('prompt' => '0.0000002')
      )
      expect(described_class.model_config('cohere/rerank-v3.5')['capabilities']).to include('rerank', 'text_input', 'text_output')
      expect(described_class.model_config('image/provider')).to be_nil
    end

    it 'infers moderation only for explicit moderation or guard models' do
      stub_request(:get, api_url)
        .with(headers: { 'Authorization' => 'Bearer [REDACTED]' })
        .to_return(
          status: 200,
          body: {
            data: [
              {
                id: 'openai/gpt-5-mini',
                name: 'GPT-5 Mini',
                description: 'Fast model with improved safety behavior.',
                architecture: { input_modalities: ['text'], output_modalities: ['text'] },
                supported_parameters: ['response_format']
              },
              {
                id: 'meta-llama/llama-guard-4-12b',
                name: 'Llama Guard 4',
                architecture: { input_modalities: ['text'], output_modalities: ['text'] },
                supported_parameters: ['response_format']
              }
            ]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      described_class.refresh!(api_key: '[REDACTED]')

      expect(described_class.model_config('openai/gpt-5-mini')['capabilities']).not_to include('moderation')
      expect(described_class.model_config('meta-llama/llama-guard-4-12b')['capabilities']).to include('moderation')
    end

    it 'normalizes dedicated OpenRouter speech-to-text models from the models API' do
      stub_request(:get, api_url)
        .with(headers: { 'Authorization' => 'Bearer [REDACTED]' })
        .to_return(
          status: 200,
          body: {
            data: [
              {
                id: 'openai/gpt-4o-mini-transcribe',
                name: 'OpenAI: GPT-4o Mini Transcribe',
                architecture: {
                  input_modalities: ['audio'],
                  output_modalities: ['transcription'],
                  modality: 'audio->transcription'
                },
                context_length: 128_000,
                pricing: {
                  prompt: '0.00000125',
                  completion: '0.000005',
                  audio: '0.000006'
                },
                supported_parameters: %w[response_format structured_outputs temperature]
              }
            ]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      metadata = described_class.refresh!(api_key: '[REDACTED]')

      expect(metadata).to include(total_models: 1, transcription_models: 1, chat_models: 0, embedding_models: 0)
      expect(described_class.model_config('openai/gpt-4o-mini-transcribe')).to include(
        'provider' => 'openrouter',
        'display_name' => 'OpenAI: GPT-4o Mini Transcribe',
        'type' => 'transcription',
        'input_modalities' => ['audio'],
        'output_modalities' => ['transcription'],
        'context_length' => 128_000,
        'pricing' => include('prompt' => '0.00000125', 'completion' => '0.000005', 'audio' => '0.000006')
      )
      expect(described_class.model_config('openai/gpt-4o-mini-transcribe')['capabilities']).to include(
        'audio_input', 'transcription', 'structured_output'
      )
    end

    it 'keeps freshly refreshed API models active when the cache store drops writes' do
      allow(cache_store).to receive(:write).and_return(false)
      allow(cache_store).to receive(:read).and_return(nil)
      stub_request(:get, api_url)
        .with(headers: { 'Authorization' => 'Bearer [REDACTED]' })
        .to_return(status: 200, body: api_response.to_json, headers: { 'Content-Type' => 'application/json' })

      metadata = described_class.refresh!(api_key: '[REDACTED]')

      expect(metadata).to include(
        total_models: 2,
        chat_models: 1,
        rerank_models: 1,
        source: 'openrouter_api',
        using_fallback: false
      )
      expect(described_class.model_config('openai/gpt-4')).to include('source' => 'openrouter_api')
      expect(described_class.model_config('cohere/rerank-v3.5')).to include('source' => 'openrouter_api')
    end

    it 'keeps refreshed API models after cache and process memory are reset' do
      stub_request(:get, api_url)
        .with(headers: { 'Authorization' => 'Bearer [REDACTED]' })
        .to_return(status: 200, body: api_response.to_json, headers: { 'Content-Type' => 'application/json' })

      described_class.refresh!(api_key: '[REDACTED]')
      Rails.cache.clear
      described_class.instance_variable_set(:@last_model_configs, nil)
      described_class.instance_variable_set(:@last_refreshed_at, nil)
      described_class.instance_variable_set(:@cached_model_configs, nil)
      described_class.instance_variable_set(:@cached_model_configs_refresh_marker, nil)
      described_class.instance_variable_set(:@cached_model_configs_loaded, nil)

      expect(described_class.model_config('openai/gpt-4')).to include('source' => 'openrouter_api')
      expect(described_class.metadata).to include(source: 'openrouter_api', using_fallback: false)
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
      expect(described_class.model_configs.keys).to contain_exactly('openai/gpt-4', 'cohere/rerank-v3.5')
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
