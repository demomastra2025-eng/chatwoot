# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ModelRegistryService do
  let(:account) { create(:account) }
  let(:registry_model) { instance_double(RubyLLM::Model::Info, type: 'chat', capabilities: %w[reasoning streaming]) }
  let(:transcription_registry_model) { instance_double(RubyLLM::Model::Info, type: 'transcription', capabilities: []) }
  let(:registry) { instance_double(RubyLLM::Models, all: [registry_model]) }
  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
    Rails.cache.clear
    allow(RubyLLM).to receive(:models).and_return(registry)
    allow(registry).to receive(:find) do |model_name|
      case model_name
      when 'gpt-5.1'
        registry_model
      when 'whisper-1'
        transcription_registry_model
      end
    end
    allow(Llm::Models).to receive(:models).and_return(
      {
        'gpt-5.1' => { 'provider' => 'openai' },
        'whisper-1' => { 'provider' => 'openai' }
      }
    )
    allow(Llm::Models).to receive(:feature_keys).and_return(%w[assistant audio_transcription])
    allow(Llm::Models).to receive(:providers).and_return(
      {
        'openai' => { 'display_name' => 'OpenAI' },
        'anthropic' => { 'display_name' => 'Anthropic' },
        'openrouter' => { 'display_name' => 'OpenRouter' }
      }
    )
    allow(Llm::Models).to receive(:provider_config) do |provider_name|
      { 'display_name' => provider_name.to_s.titleize }
    end
    allow(Llm::Models).to receive(:registry_known?).and_return(true)
    allow(Llm::Config).to receive(:installation_default_model).and_return('gpt-5.1')
    allow(Llm::Config).to receive(:moderation_model).and_return('omni-moderation-latest')
    allow(Llm::Config).to receive(:provider_available?) do |provider_name|
      provider_name.to_s == 'openai'
    end
    allow(Llm::Config).to receive(:custom_api_base_configured?).and_return(false)
    allow(Llm::Config).to receive(:model_for).with(feature: 'assistant', account: account).and_return('gpt-5.1')
    allow(Llm::Config).to receive(:model_for).with(feature: 'audio_transcription', account: account).and_return('whisper-1')
    allow(Llm::Config).to receive(:provider_for_model).with('gpt-5.1').and_return('openai')
    allow(Llm::Config).to receive(:provider_for_model).with('whisper-1').and_return('openai')
    allow(Llm::Models).to receive(:type_for).with('gpt-5.1').and_return('chat')
    allow(Llm::Models).to receive(:type_for).with('whisper-1').and_return('transcription')
    allow(Llm::Models).to receive(:capabilities_for).with('gpt-5.1').and_return(%w[reasoning streaming])
    allow(Llm::Models).to receive(:capabilities_for).with('whisper-1').and_return([])
    allow(Llm::Models).to receive(:supports_thinking?).with('gpt-5.1').and_return(true)
    allow(Llm::Models).to receive(:supports_thinking?).with('whisper-1').and_return(false)
  end

  describe '.runtime_metadata' do
    it 'returns provider, registry, and feature metadata for AI settings' do
      metadata = described_class.runtime_metadata(account: account)

      expect(metadata[:defaults]).to include(
        installation_default_model: 'gpt-5.1',
        moderation_model: 'omni-moderation-latest'
      )
      expect(metadata.dig(:providers, 'openai')).to include(
        display_name: 'OpenAI',
        configured: true
      )
      expect(metadata.dig(:providers, 'openrouter')).to include(
        display_name: 'OpenRouter',
        configured: false,
        models_api: include(:total_models, :using_fallback)
      )
      expect(metadata.dig(:registry, :openrouter)).to include(:total_models, :using_fallback)
      expect(metadata.dig(:features, 'assistant')).to include(
        selected_model: 'gpt-5.1',
        provider: 'openai',
        supports_thinking: true
      )
    end
  end

  describe '.refresh!' do
    it 'refreshes the RubyLLM registry and records the refresh timestamp' do
      expect(registry).to receive(:refresh!).with(remote_only: true).and_return(registry)

      metadata = described_class.refresh!

      expect(metadata[:total_models]).to eq(1)
      expect(metadata[:last_refreshed_at]).to be_present
      expect(Rails.cache.read(described_class::LAST_REFRESH_AT_CACHE_KEY)).to be_present
    end
  end

  describe '.refresh_openrouter!' do
    it 'refreshes LLM config and OpenRouter models through the catalog' do
      expect(Llm::Config).to receive(:reset!)
      expect(Llm::Config).to receive(:initialize!)
      expect(Llm::OpenRouterModelCatalog).to receive(:refresh!).and_return(total_models: 1)

      expect(described_class.refresh_openrouter!).to eq(total_models: 1)
    end
  end
end
