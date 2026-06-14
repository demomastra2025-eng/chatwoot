# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Models do
  describe '.capabilities_for' do
    it 'normalizes upstream registry capabilities to onelink capability names' do
      registry_info = instance_double(RubyLLM::Model::Info, capabilities: %w[function_calling vision], type: 'chat')
      allow(described_class).to receive(:registry_info_for).with('custom-model').and_return(registry_info)

      expect(described_class.capabilities_for('custom-model')).to include('tool_calling', 'multimodal_input')
    end

    it 'does not merge stale registry capabilities into dynamic OpenRouter models' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-5-chat' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[streaming text_input text_output structured_output]
        }
      )
      registry_info = instance_double(
        RubyLLM::Model::Info,
        capabilities: %w[structured_output reasoning function_calling],
        type: 'chat'
      )
      allow(described_class).to receive(:registry_info_for).with('openai/gpt-5-chat').and_return(registry_info)

      capabilities = described_class.capabilities_for('openai/gpt-5-chat')

      expect(capabilities).to include('streaming', 'structured_output')
      expect(capabilities).not_to include('reasoning', 'tool_calling')
    end
  end

  describe '.providers' do
    it 'loads only OpenRouter as the normal runtime provider from llm.yml' do
      expect(described_class.providers.keys).to eq(['openrouter'])
    end

    it 'keeps direct provider metadata available only for legacy stored model compatibility' do
      expect(described_class.legacy_providers.keys).to include('openai', 'anthropic', 'gemini')
      expect(described_class.provider_config('openai')).to include('api_key_config' => 'CAPTAIN_OPEN_AI_API_KEY')
    end
  end

  describe '.features' do
    it 'uses OpenRouter model ids as normal Captain feature defaults' do
      expect(described_class.features.dig('editor', 'default')).to eq('openai/gpt-5.4-mini')
      expect(described_class.features.dig('assistant', 'default')).to eq('openai/gpt-5.4')
      expect(described_class.features.dig('copilot', 'default')).to eq('openai/gpt-5.4')
      expect(described_class.features.dig('image_recognition', 'default')).to eq('openai/gpt-5.4-mini')
      expect(described_class.features.dig('audio_transcription', 'default')).to eq('openai/gpt-4o-mini-transcribe')
      expect(described_class.features.dig('moderation', 'default')).to eq('openai/gpt-oss-safeguard-20b')
    end
  end

  describe '.valid_model_for?' do
    it 'checks the requested model without expanding the full feature model list' do
      account = create(:account)

      expect(described_class).not_to receive(:models_for)
      allow(described_class).to receive(:model_allowed_for_feature?)
        .with(:assistant, 'openai/gpt-5.4', account: account)
        .and_return(true)

      expect(described_class.valid_model_for?(:assistant, 'openai/gpt-5.4', account: account)).to be true
    end
  end

  describe '.provider_for' do
    it 'returns the configured provider for a model' do
      expect(described_class.provider_for('claude-sonnet-4-6')).to eq('anthropic')
    end

    it 'returns OpenRouter for provider-prefixed dynamic model ids discovered from OpenRouter' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-4o' => { 'provider' => 'openrouter', 'type' => 'chat', 'capabilities' => %w[streaming] }
      )

      expect(described_class.provider_for('openai/gpt-4o')).to eq('openrouter')
    end

    it 'infers OpenRouter for provider-prefixed ids without falling back to OpenAI' do
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return({})

      expect(described_class.provider_for('unknown/provider-model')).to eq('openrouter')
    end
  end

  describe '.supports_thinking?' do
    it 'returns true for reasoning-capable models' do
      expect(described_class.supports_thinking?('gpt-5.4')).to be true
      expect(described_class.supports_thinking?('claude-sonnet-4-6')).to be true
      expect(described_class.supports_thinking?('gemini-2.5-pro')).to be true
    end

    it 'returns false for non-reasoning models' do
      expect(described_class.supports_thinking?('gpt-4.1-mini')).to be false
      expect(described_class.supports_thinking?('whisper-1')).to be false
    end
  end

  describe 'capability helpers' do
    it 'exposes structured output, tool calling, multimodal, streaming, embedding, and transcription support' do
      expect(described_class.supports_structured_output?('gpt-4.1-mini')).to be true
      expect(described_class.supports_tool_calling?('gpt-4.1-mini')).to be true
      expect(described_class.supports_multimodal_input?('gpt-4.1-mini')).to be true
      expect(described_class.supports_image_input?('gpt-4.1-mini')).to be true
      expect(described_class.supports_streaming?('gpt-4.1-mini')).to be true
      expect(described_class.supports_embedding?('text-embedding-3-small')).to be true
      expect(described_class.supports_transcription?('whisper-1')).to be true
    end
  end

  describe '.feature_config' do
    it 'includes provider and capabilities metadata for OpenRouter feature models' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'anthropic/claude-sonnet-4-6' => {
          'provider' => 'openrouter',
          'display_name' => 'Claude Sonnet 4.6 via OpenRouter',
          'type' => 'chat',
          'capabilities' => %w[reasoning structured_output tool_calling tool_choice streaming]
        }
      )

      config = described_class.feature_config(:assistant)
      claude = config[:models].find { |model| model[:id] == 'anthropic/claude-sonnet-4-6' }

      expect(claude).to include(
        provider: 'openrouter',
        type: 'chat'
      )
      expect(claude[:capabilities]).to include('reasoning', 'structured_output', 'tool_calling')
    end

    it 'includes dynamically fetched OpenRouter chat models that satisfy assistant capabilities when OpenRouter is configured' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-4o' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT-4o via OpenRouter',
          'type' => 'chat',
          'source' => 'openrouter_api',
          'context_length' => 128_000,
          'max_output_tokens' => 16_384,
          'input_modalities' => %w[text image],
          'output_modalities' => ['text'],
          'pricing' => { 'prompt' => '0.000001', 'completion' => '0.000002' },
          'latency_ms' => 420.0,
          'throughput_tokens_per_second' => 87.5,
          'capabilities' => %w[structured_output tool_calling tool_choice image_input streaming]
        },
        'tool/without-image-input' => {
          'provider' => 'openrouter',
          'display_name' => 'Tool Calls Text Only',
          'type' => 'chat',
          'capabilities' => %w[structured_output tool_calling tool_choice streaming]
        },
        'tool/without-structured-output' => {
          'provider' => 'openrouter',
          'display_name' => 'Tool Calls Only',
          'type' => 'chat',
          'capabilities' => %w[tool_calling image_input streaming]
        },
        'text/only' => {
          'provider' => 'openrouter',
          'display_name' => 'Text Only',
          'type' => 'chat',
          'capabilities' => %w[streaming]
        }
      )

      config = described_class.feature_config(:assistant)

      expect(config[:models]).to include(
        hash_including(
          id: 'openai/gpt-4o',
          display_name: 'GPT-4o via OpenRouter',
          provider: 'openrouter',
          provider_display_name: 'OpenRouter',
          provider_configured: true,
          account_configured: false,
          global_configured: false,
          source: 'openrouter_api',
          context_length: 128_000,
          max_output_tokens: 16_384,
          input_modalities: %w[text image],
          output_modalities: ['text'],
          pricing: { 'prompt' => '0.000001', 'completion' => '0.000002' },
          latency_ms: 420.0,
          throughput_tokens_per_second: 87.5,
          capabilities: include('structured_output', 'tool_calling', 'tool_choice', 'image_input'),
          diagnostics: include(allowed: true, reasons: [])
        )
      )
      expect(config[:models]).to include(hash_including(id: 'tool/without-image-input'))
      expect(config[:models]).not_to include(hash_including(id: 'tool/without-structured-output'))
      expect(config[:models]).not_to include(hash_including(id: 'text/only'))
    end

    it 'adds reasoning to assistant requirements only when Captain thinking is enabled' do
      account = create(:account, captain_runtime: { 'assistant_thinking_effort' => 'low' })
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'global-openrouter-key')
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-reasoning' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT Reasoning',
          'type' => 'chat',
          'capabilities' => %w[structured_output tool_calling tool_choice reasoning streaming]
        },
        'openai/gpt-no-reasoning' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT No Reasoning',
          'type' => 'chat',
          'capabilities' => %w[structured_output tool_calling tool_choice streaming]
        }
      )

      config = described_class.feature_config(:assistant, account: account)

      expect(config[:required_capabilities]).to include('reasoning')
      expect(config[:models]).to include(hash_including(id: 'openai/gpt-reasoning'))
      expect(config[:models]).not_to include(hash_including(id: 'openai/gpt-no-reasoning'))
      expect(config[:diagnostic_models]).to include(
        hash_including(
          id: 'openai/gpt-no-reasoning',
          diagnostics: include(reasons: include(hash_including(code: 'reasoning_unsupported')))
        )
      )
    end

    it 'keeps empty-requirement text features limited to OpenRouter chat models' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-4o-mini' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT-4o Mini via OpenRouter',
          'type' => 'chat',
          'capabilities' => %w[streaming]
        },
        'openai/text-embedding-3-small' => {
          'provider' => 'openrouter',
          'display_name' => 'Text Embedding 3 Small via OpenRouter',
          'type' => 'embedding',
          'capabilities' => %w[embedding]
        },
        'openai/gpt-4o-mini-transcribe' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT-4o Mini Transcribe via OpenRouter',
          'type' => 'transcription',
          'capabilities' => %w[audio_input transcription]
        }
      )

      editor_config = described_class.feature_config(:editor)
      label_config = described_class.feature_config(:label_suggestion)

      expect(editor_config[:models]).to include(hash_including(id: 'openai/gpt-4o-mini'))
      expect(label_config[:models]).to include(hash_including(id: 'openai/gpt-4o-mini'))
      expect(editor_config[:models]).not_to include(hash_including(id: 'openai/text-embedding-3-small'))
      expect(editor_config[:models]).not_to include(hash_including(id: 'openai/gpt-4o-mini-transcribe'))
      expect(label_config[:models]).not_to include(hash_including(id: 'openai/text-embedding-3-small'))
      expect(label_config[:models]).not_to include(hash_including(id: 'openai/gpt-4o-mini-transcribe'))
    end

    it 'exposes dynamic OpenRouter rerank models for knowledge rerank' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'cohere/rerank-v3.5' => {
          'provider' => 'openrouter',
          'display_name' => 'Cohere Rerank 3.5 via OpenRouter',
          'type' => 'rerank',
          'capabilities' => %w[rerank text_input text_output]
        },
        'openai/gpt-4o-mini' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT-4o Mini via OpenRouter',
          'type' => 'chat',
          'capabilities' => %w[streaming]
        }
      )

      config = described_class.feature_config(:knowledge_rerank)

      expect(config[:models]).to include(
        hash_including(
          id: 'cohere/rerank-v3.5',
          provider: 'openrouter',
          type: 'rerank',
          capabilities: include('rerank'),
          diagnostics: include(allowed: true, reasons: [])
        )
      )
      expect(config[:models]).not_to include(hash_including(id: 'openai/gpt-4o-mini'))
    end

    it 'filters image recognition OpenRouter models by image input support' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-4o' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT-4o via OpenRouter',
          'type' => 'chat',
          'capabilities' => %w[image_input text_output streaming]
        },
        'text/only' => {
          'provider' => 'openrouter',
          'display_name' => 'Text Only',
          'type' => 'chat',
          'capabilities' => %w[text_output streaming]
        }
      )

      config = described_class.feature_config(:image_recognition)

      expect(config[:models]).to include(hash_including(id: 'openai/gpt-4o'))
      expect(config[:models]).not_to include(hash_including(id: 'text/only'))
      expect(config[:required_capabilities]).to eq(%w[image_input])
    end

    it 'does not expose normal Captain fallback models when OpenRouter is not configured' do
      allow(Llm::Config).to receive(:provider_available?).and_return(false)
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-4o' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT-4o via OpenRouter',
          'type' => 'chat',
          'capabilities' => %w[structured_output tool_calling tool_choice streaming]
        }
      )

      config = described_class.feature_config(:assistant)

      expect(config[:models]).not_to include(hash_including(id: 'openai/gpt-4o'))
      expect(config[:models]).not_to include(hash_including(provider: 'openai'))
      expect(config[:models]).not_to include(hash_including(provider: 'anthropic'))
      expect(config[:models]).not_to include(hash_including(provider: 'gemini'))
      expect(config[:default]).to be_nil
    end

    it 'hides account feature models for providers without a configured key' do
      account = create(:account)
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'global-openrouter-key')
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-5.4' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT-5.4 via OpenRouter',
          'type' => 'chat',
          'capabilities' => %w[structured_output tool_calling tool_choice image_input streaming]
        }
      )

      config = described_class.feature_config(:assistant, account: account)

      expect(config[:models]).to include(
        hash_including(
          id: 'openai/gpt-5.4',
          provider: 'openrouter',
          provider_configured: true,
          account_configured: false,
          global_configured: true
        )
      )
      expect(config[:models]).not_to include(hash_including(id: 'gpt-5.4'))
      expect(config[:models]).to all(include(provider_configured: true))
    end

    it 'hides direct account-key models from normal Captain feature configs' do
      account = create(:account)
      create(
        :integrations_hook,
        :openai,
        account: account,
        access_token: 'account-openai-key',
        settings: { api_key: 'account-openai-key' }
      )
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'global-openrouter-key')
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-5.4' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT-5.4 via OpenRouter',
          'type' => 'chat',
          'capabilities' => %w[structured_output tool_calling tool_choice streaming]
        }
      )

      config = described_class.feature_config(:assistant, account: account)

      expect(config[:models]).to include(
        hash_including(
          id: 'openai/gpt-5.4',
          provider: 'openrouter',
          provider_configured: true,
          account_configured: false,
          global_configured: true
        )
      )
      expect(config[:models]).not_to include(hash_including(id: 'gpt-5.4'))
      expect(config[:models]).not_to include(hash_including(provider: 'openai'))
    end

    it 'uses OpenRouter default equivalents only when the OpenRouter catalog has a capability-compatible model' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-5.4' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT-5.4 via OpenRouter',
          'type' => 'chat',
          'capabilities' => %w[structured_output tool_calling tool_choice image_input streaming]
        },
        'openai/gpt-4o-mini-transcribe' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT-4o Mini Transcribe via OpenRouter',
          'type' => 'transcription',
          'source' => 'openrouter_api',
          'input_modalities' => ['audio'],
          'output_modalities' => ['transcription'],
          'capabilities' => %w[audio_input transcription]
        }
      )

      expect(described_class.feature_config(:assistant)[:default]).to eq('openai/gpt-5.4')
      expect(described_class.feature_config(:audio_transcription)[:default]).to eq('openai/gpt-4o-mini-transcribe')
      expect(described_class.feature_config(:audio_transcription)[:models]).to include(
        hash_including(
          id: 'openai/gpt-4o-mini-transcribe',
          display_name: 'GPT-4o Mini Transcribe via OpenRouter',
          source: 'openrouter_api',
          input_modalities: ['audio'],
          output_modalities: ['transcription']
        )
      )
    end

    it 'does not use stale static OpenRouter capabilities when the live catalog has an incompatible model with the same id' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-5.4' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT-5.4 via OpenRouter',
          'type' => 'chat',
          'capabilities' => %w[streaming]
        }
      )

      config = described_class.feature_config(:assistant)

      expect(config[:default]).to be_nil
      expect(config[:models]).not_to include(hash_including(id: 'openai/gpt-5.4'))
    end

    it 'offers static capability-safe OpenRouter models for audio transcription, image recognition, and moderation when the live catalog is empty' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return({})

      audio_config = described_class.feature_config(:audio_transcription)
      image_config = described_class.feature_config(:image_recognition)
      moderation_config = described_class.feature_config(:moderation)

      expect(audio_config[:default]).to eq('openai/gpt-4o-mini-transcribe')
      expect(audio_config[:models]).to include(
        hash_including(id: 'openai/gpt-4o-mini-transcribe', provider: 'openrouter', capabilities: include('audio_input', 'transcription')),
        hash_including(id: 'openai/gpt-audio-mini', provider: 'openrouter', capabilities: include('audio_input', 'transcription'))
      )
      expect(image_config[:default]).to eq('openai/gpt-5.4-mini')
      expect(image_config[:models]).to include(
        hash_including(id: 'openai/gpt-5.4-mini', provider: 'openrouter', capabilities: include('image_input'))
      )
      expect(moderation_config[:default]).to eq('openai/gpt-oss-safeguard-20b')
      expect(moderation_config[:models]).to include(
        hash_including(id: 'openai/gpt-oss-safeguard-20b', provider: 'openrouter', capabilities: include('structured_output', 'moderation'))
      )
    end

    it 'filters OpenRouter audio recognition models to transcription-capable chat or STT models' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openrouter/auto' => {
          'provider' => 'openrouter',
          'display_name' => 'Auto Router',
          'type' => 'chat',
          'capabilities' => %w[audio_input text_output structured_output]
        },
        'google/gemini-3.1-pro-preview-customtools' => {
          'provider' => 'openrouter',
          'display_name' => 'Gemini Custom Tools',
          'type' => 'chat',
          'capabilities' => %w[audio_input text_output structured_output]
        },
        'openai/gpt-4o-mini-transcribe' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT-4o Mini Transcribe',
          'type' => 'transcription',
          'capabilities' => %w[audio_input transcription]
        },
        'openai/gpt-audio-mini' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT Audio Mini',
          'type' => 'chat',
          'capabilities' => %w[audio_input text_output transcription structured_output]
        }
      )

      config = described_class.feature_config(:audio_transcription)

      expect(config[:models]).to include(hash_including(id: 'openai/gpt-4o-mini-transcribe'))
      expect(config[:models]).to include(hash_including(id: 'openai/gpt-audio-mini'))
      expect(config[:models]).not_to include(hash_including(id: 'openrouter/auto'))
      expect(config[:models]).not_to include(hash_including(id: 'google/gemini-3.1-pro-preview-customtools'))
      expect(config[:required_capabilities]).to eq(%w[audio_input transcription])
    end

    it 'filters OpenRouter moderation models to safety/moderation-capable structured models' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-4o' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT-4o',
          'type' => 'chat',
          'capabilities' => %w[text_input text_output structured_output]
        },
        'meta-llama/llama-guard-4-12b' => {
          'provider' => 'openrouter',
          'display_name' => 'Llama Guard 4',
          'type' => 'chat',
          'capabilities' => %w[text_input text_output structured_output moderation]
        },
        'safety/no-structured-output' => {
          'provider' => 'openrouter',
          'display_name' => 'Safety Text Only',
          'type' => 'chat',
          'capabilities' => %w[text_input text_output moderation]
        }
      )

      config = described_class.feature_config(:moderation)

      expect(config[:models]).to include(hash_including(id: 'meta-llama/llama-guard-4-12b'))
      expect(config[:models]).not_to include(hash_including(id: 'openai/gpt-4o'))
      expect(config[:models]).not_to include(hash_including(id: 'safety/no-structured-output'))
      expect(config[:required_capabilities]).to eq(%w[text_input text_output structured_output moderation])
    end

    it 'keeps the configured embedding default when OpenRouter catalog is enabled' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| %w[openrouter openai].include?(provider) }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return({})

      help_center_config = described_class.feature_config(:help_center_search)

      expect(help_center_config[:default]).to eq('text-embedding-3-small')
      expect(help_center_config[:models]).to include(
        hash_including(
          id: 'text-embedding-3-small',
          provider: 'openrouter',
          capabilities: include('embedding'),
          context_length: 8191,
          embedding_dimensions: 1536
        )
      )
      expect(help_center_config[:required_capabilities]).to eq(%w[embedding])
    end

    it 'includes dynamically fetched OpenRouter embedding models compatible with the knowledge index' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/text-embedding-3-small' => {
          'provider' => 'openrouter',
          'display_name' => 'Text Embedding 3 Small',
          'type' => 'embedding',
          'capabilities' => %w[embedding text_input],
          'input_modalities' => ['text'],
          'output_modalities' => ['embeddings'],
          'embedding_dimensions' => 1536,
          'requested_embedding_dimensions' => 1536,
          'supported_embedding_dimensions' => [1536],
          'supports_embedding_dimension_override' => true,
          'supports_embedding_input_type' => true,
          'context_length' => 8192,
          'pricing' => { 'prompt' => '0.00000002', 'completion' => '0' }
        },
        'baai/bge-m3' => {
          'provider' => 'openrouter',
          'display_name' => 'BGE M3',
          'type' => 'embedding',
          'capabilities' => %w[embedding text_input],
          'input_modalities' => ['text'],
          'output_modalities' => ['embeddings'],
          'embedding_dimensions' => 1536,
          'context_length' => 8192
        },
        'openai/text-embedding-resizable' => {
          'provider' => 'openrouter',
          'display_name' => 'Resizable Embedding',
          'type' => 'embedding',
          'capabilities' => %w[embedding text_input],
          'embedding_dimensions' => 3072,
          'requested_embedding_dimensions' => 1536,
          'context_length' => 8192
        },
        'openai/text-embedding-wrong-dimensions' => {
          'provider' => 'openrouter',
          'display_name' => 'Wrong Dimensions',
          'type' => 'embedding',
          'capabilities' => %w[embedding text_input],
          'embedding_dimensions' => 1024,
          'context_length' => 8192
        },
        'openai/text-embedding-too-small' => {
          'provider' => 'openrouter',
          'display_name' => 'Too Small Context',
          'type' => 'embedding',
          'capabilities' => %w[embedding text_input],
          'input_modalities' => ['text'],
          'output_modalities' => ['embeddings'],
          'embedding_dimensions' => 1536,
          'context_length' => 2000
        },
        'openai/text-embedding-unknown-context' => {
          'provider' => 'openrouter',
          'display_name' => 'Unknown Context',
          'type' => 'embedding',
          'capabilities' => %w[embedding text_input],
          'input_modalities' => ['text'],
          'output_modalities' => ['embeddings'],
          'embedding_dimensions' => 1536
        },
        'openai/text-embedding-3-small-chat-lookalike' => {
          'provider' => 'openrouter',
          'display_name' => 'Chat Lookalike',
          'type' => 'chat',
          'capabilities' => %w[embedding text_input]
        }
      )

      help_center_config = described_class.feature_config(:help_center_search)
      runtime_models = described_class.models_for(:help_center_search)

      expect(help_center_config[:default]).to eq('openai/text-embedding-3-small')
      expect(help_center_config[:models]).to include(
        hash_including(
          id: 'openai/text-embedding-3-small',
          type: 'embedding',
          capabilities: include('embedding'),
          input_modalities: ['text'],
          output_modalities: ['embeddings'],
          embedding_dimensions: 1536,
          requested_embedding_dimensions: 1536,
          supported_embedding_dimensions: [1536],
          supports_embedding_dimension_override: true,
          supports_embedding_input_type: true,
          context_length: 8192,
          pricing: { 'prompt' => '0.00000002', 'completion' => '0' }
        )
      )
      expect(help_center_config[:models]).not_to include(hash_including(id: 'text-embedding-3-small'))
      expect(help_center_config[:models]).to include(hash_including(id: 'baai/bge-m3'))
      expect(help_center_config[:models]).to include(hash_including(id: 'openai/text-embedding-resizable'))
      expect(help_center_config[:models]).not_to include(hash_including(id: 'openai/text-embedding-wrong-dimensions'))
      expect(help_center_config[:models]).to include(hash_including(id: 'openai/text-embedding-too-small'))
      expect(help_center_config[:models]).to include(hash_including(id: 'openai/text-embedding-unknown-context'))
      expect(runtime_models).not_to include('openai/text-embedding-too-small')
      expect(runtime_models).not_to include('openai/text-embedding-unknown-context')
      expect(runtime_models).not_to include('openai/text-embedding-wrong-dimensions')
      expect(help_center_config[:models]).not_to include(hash_including(id: 'openai/text-embedding-3-small-chat-lookalike'))
    end

    it 'keeps embedding model settings visible while enforcing the account knowledge chunk size' do
      account = create(:account, captain_runtime: { 'knowledge_chunk_size' => 40_000 })
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/text-embedding-3-small' => {
          'provider' => 'openrouter',
          'display_name' => 'Text Embedding 3 Small',
          'type' => 'embedding',
          'capabilities' => %w[embedding text_input],
          'embedding_dimensions' => 1536,
          'context_length' => 8192
        },
        'openai/text-embedding-long-context' => {
          'provider' => 'openrouter',
          'display_name' => 'Long Context Embedding',
          'type' => 'embedding',
          'capabilities' => %w[embedding text_input],
          'embedding_dimensions' => 1536,
          'context_length' => 16_384
        }
      )

      help_center_config = described_class.feature_config(:help_center_search, account: account)
      runtime_models = described_class.models_for(:help_center_search, account: account)

      expect(help_center_config[:models]).to include(hash_including(id: 'openai/text-embedding-long-context'))
      expect(help_center_config[:models]).to include(hash_including(id: 'openai/text-embedding-3-small'))
      expect(help_center_config[:models]).not_to include(hash_including(id: 'text-embedding-3-small'))
      expect(runtime_models).to include('openai/text-embedding-long-context')
      expect(runtime_models).not_to include('openai/text-embedding-3-small')
      expect(described_class.valid_model_for?(:help_center_search, 'openai/text-embedding-3-small', account: account)).to be false
      expect(help_center_config[:default]).to eq('openai/text-embedding-long-context')
    end

    it 'exposes chunk size options backed by compatible OpenRouter embedding models' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/text-embedding-3-small' => {
          'provider' => 'openrouter',
          'display_name' => 'Text Embedding 3 Small',
          'type' => 'embedding',
          'capabilities' => %w[embedding text_input],
          'embedding_dimensions' => 1536,
          'context_length' => 8192
        }
      )

      options = described_class.knowledge_chunk_size_options

      expect(options).to include(
        include(value: 20_000, estimated_tokens: 5000, available_model_count: 1, disabled: false),
        include(value: 32_000, estimated_tokens: 8000, available_model_count: 1, disabled: false)
      )
      expect(options).not_to include(include(value: 40_000))
    end
  end

  describe '.canonical_model_name' do
    it 'normalizes legacy Anthropic dotted aliases to canonical ids' do
      expect(described_class.canonical_model_name('claude-sonnet-4.6')).to eq('claude-sonnet-4-6')
      expect(described_class.canonical_model_name('claude-opus-4.6')).to eq('claude-opus-4-6')
    end
  end

  describe '.runtime_supported?' do
    it 'allows configured Anthropic ids even when the RubyLLM registry does not know them yet' do
      allow(described_class).to receive(:registry_known?).with('claude-sonnet-4-6').and_return(false)

      expect(described_class.runtime_supported?('claude-sonnet-4-6')).to be true
    end

    it 'allows OpenRouter provider-prefixed model ids discovered from OpenRouter even when RubyLLM has not refreshed them yet' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-4o' => { 'provider' => 'openrouter', 'type' => 'chat', 'capabilities' => %w[streaming] }
      )
      allow(described_class).to receive(:registry_model_for).with('openai/gpt-4o').and_return(nil)

      expect(described_class.runtime_supported?('openai/gpt-4o')).to be true
    end
  end

  describe '.model_allowed_for_feature?' do
    it 'checks a selected OpenRouter model without building the full feature model list' do
      account = create(:account)
      model_id = 'deepseek/deepseek-v4-pro'

      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        model_id => {
          'provider' => 'openrouter',
          'display_name' => 'DeepSeek V4 Pro',
          'type' => 'chat',
          'capabilities' => %w[text_input text_output structured_output tool_calling tool_choice],
          'context_length' => 128_000
        }
      )
      allow(Llm::OpenRouterEndpointCatalog).to receive(:endpoint_metadata).with(model_id).and_return(
        'endpoints' => [
          { 'provider_name' => 'deepseek', 'capabilities' => %w[structured_output tool_calling tool_choice] }
        ]
      )
      expect(described_class).not_to receive(:models_for)

      expect(described_class.model_allowed_for_feature?(:assistant, model_id, account: account)).to be true
    end
  end

  describe 'pricing helpers' do
    it 'exposes configured credit multipliers' do
      expect(described_class.credit_multiplier_for('gpt-4.1-mini')).to eq(1)
      expect(described_class.credit_multiplier_for('gpt-5.4')).to eq(4)
    end

    it 'estimates text cost from registry pricing when available' do
      registry_model = instance_double(
        RubyLLM::Model::Info,
        input_price_per_million: 0.5,
        output_price_per_million: 1.5
      )
      allow(described_class).to receive(:registry_model_for).with('custom-model').and_return(registry_model)

      expect(
        described_class.estimated_text_cost('custom-model', input_tokens: 1_000_000, output_tokens: 500_000)
      ).to eq(1.25)
    end
  end
end
