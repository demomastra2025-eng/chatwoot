# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Models do
  describe '.capabilities_for' do
    it 'normalizes upstream registry capabilities to onelink capability names' do
      registry_info = instance_double('RubyLLM::Model::Info', capabilities: %w[function_calling vision], type: 'chat')
      allow(described_class).to receive(:registry_info_for).with('custom-model').and_return(registry_info)

      expect(described_class.capabilities_for('custom-model')).to include('tool_calling', 'multimodal_input')
    end
  end

  describe '.providers' do
    it 'loads providers from llm.yml' do
      expect(described_class.providers.keys).to include('openai', 'anthropic', 'gemini', 'openrouter')
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
    it 'includes provider and capabilities metadata for feature models' do
      config = described_class.feature_config(:assistant)
      claude = config[:models].find { |model| model[:id] == 'claude-sonnet-4-6' }

      expect(claude).to include(
        provider: 'anthropic',
        type: 'chat'
      )
      expect(claude[:capabilities]).to include('reasoning', 'structured_output', 'tool_calling')
    end

    it 'includes dynamically fetched OpenRouter models that satisfy feature capabilities when OpenRouter is configured' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-4o' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT-4o via OpenRouter',
          'type' => 'chat',
          'source' => 'openrouter_api',
          'context_length' => 128_000,
          'max_output_tokens' => 16_384,
          'capabilities' => %w[structured_output tool_calling image_input streaming]
        },
        'tool/without-image-input' => {
          'provider' => 'openrouter',
          'display_name' => 'Tool Calls Text Only',
          'type' => 'chat',
          'capabilities' => %w[structured_output tool_calling streaming]
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
          capabilities: include('structured_output', 'tool_calling', 'image_input')
        )
      )
      expect(config[:models]).not_to include(hash_including(id: 'tool/without-image-input'))
      expect(config[:models]).not_to include(hash_including(id: 'tool/without-structured-output'))
      expect(config[:models]).not_to include(hash_including(id: 'text/only'))
    end

    it 'does not include OpenRouter catalog models when OpenRouter is not configured' do
      allow(Llm::Config).to receive(:provider_available?).and_return(false)
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-4o' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT-4o via OpenRouter',
          'type' => 'chat',
          'capabilities' => %w[structured_output tool_calling streaming]
        }
      )

      config = described_class.feature_config(:assistant)

      expect(config[:models]).not_to include(hash_including(id: 'openai/gpt-4o'))
      expect(config[:default]).to eq('gpt-5.4')
    end

    it 'uses OpenRouter default equivalents only when the OpenRouter catalog has a capability-compatible model' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-5.4' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT-5.4 via OpenRouter',
          'type' => 'chat',
          'capabilities' => %w[structured_output tool_calling image_input streaming]
        },
        'openai/gpt-audio-mini' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT Audio Mini via OpenRouter',
          'type' => 'chat',
          'capabilities' => %w[audio_input text_output structured_output streaming]
        }
      )

      expect(described_class.feature_config(:assistant)[:default]).to eq('openai/gpt-5.4')
      expect(described_class.feature_config(:audio_transcription)[:default]).to eq('openai/gpt-audio-mini')
    end

    it 'uses the static OpenRouter alias instead of falling back to a direct OpenAI model when the live catalog lacks a compatible assistant model' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-5.4' => {
          'provider' => 'openrouter',
          'display_name' => 'GPT-5.4 via OpenRouter',
          'type' => 'chat',
          'capabilities' => %w[streaming]
        }
      )

      expect(described_class.feature_config(:assistant)[:default]).to eq('openai/gpt-5.4')
    end

    it 'offers static capability-safe OpenRouter models for audio transcription and moderation when the live catalog is empty' do
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return({})

      audio_config = described_class.feature_config(:audio_transcription)
      moderation_config = described_class.feature_config(:moderation)

      expect(audio_config[:default]).to eq('openai/gpt-4o-audio-preview')
      expect(audio_config[:models]).to include(
        hash_including(id: 'openai/gpt-4o-audio-preview', provider: 'openrouter', capabilities: include('audio_input'))
      )
      expect(moderation_config[:default]).to eq('openai/gpt-oss-safeguard-20b')
      expect(moderation_config[:models]).to include(
        hash_including(id: 'openai/gpt-oss-safeguard-20b', provider: 'openrouter', capabilities: include('structured_output'))
      )
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

  describe 'pricing helpers' do
    it 'exposes configured credit multipliers' do
      expect(described_class.credit_multiplier_for('gpt-4.1-mini')).to eq(1)
      expect(described_class.credit_multiplier_for('gpt-5.4')).to eq(4)
    end

    it 'estimates text cost from registry pricing when available' do
      registry_model = instance_double(
        'RubyLLM::Model::Info',
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
