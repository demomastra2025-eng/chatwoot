# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterModelMigration do
  before do
    upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'global-openrouter-key')
  end

  describe '.resolve' do
    it 'maps legacy direct chat model ids to OpenRouter equivalents for normal Captain features' do
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-5.4' => chat_model_config,
        'anthropic/claude-sonnet-4-6' => chat_model_config,
        'google/gemini-2.5-pro' => chat_model_config
      )

      expect(described_class.resolve('gpt-5.4', feature: :assistant)).to eq('openai/gpt-5.4')
      expect(described_class.resolve('claude-sonnet-4.6', feature: :assistant)).to eq('anthropic/claude-sonnet-4-6')
      expect(described_class.resolve('gemini-2.5-pro', feature: :assistant)).to eq('google/gemini-2.5-pro')
    end

    it 'maps legacy audio, moderation, and embedding ids through explicit OpenRouter candidates' do
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-4o-transcribe' => {
          'provider' => 'openrouter',
          'type' => 'transcription',
          'capabilities' => %w[audio_input transcription]
        },
        'openai/gpt-oss-safeguard-20b' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[text_input text_output structured_output moderation]
        },
        'openai/text-embedding-3-small' => {
          'provider' => 'openrouter',
          'type' => 'embedding',
          'capabilities' => %w[embedding text_input],
          'embedding_dimensions' => 1536,
          'context_length' => 8192
        }
      )

      expect(described_class.resolve('gpt-4o-transcribe', feature: :audio_transcription)).to eq('openai/gpt-4o-transcribe')
      expect(described_class.resolve('omni-moderation-latest', feature: :moderation)).to eq('openai/gpt-oss-safeguard-20b')
      expect(described_class.resolve('text-embedding-3-small', feature: :help_center_search)).to eq('openai/text-embedding-3-small')
    end

    it 'does not map Gemini Live voice model ids' do
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'google/gemini-3.1-flash-live-preview' => chat_model_config
      )

      expect(described_class.resolve('gemini-live', feature: :ai_voice)).to eq('gemini-live')
      expect(described_class.resolve('gemini-3.1-flash-live-preview', feature: :telephony_ai_voice)).to eq('gemini-3.1-flash-live-preview')
    end

    it 'returns nil when OpenRouter has no compatible normal-feature target' do
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-5.4' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[streaming]
        }
      )

      expect(described_class.resolve('gpt-5.4', feature: :assistant)).to be_nil
    end
  end

  def chat_model_config
    {
      'provider' => 'openrouter',
      'type' => 'chat',
      'capabilities' => %w[structured_output tool_calling streaming]
    }
  end
end
