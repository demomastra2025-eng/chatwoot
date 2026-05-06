# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Llm::EmbeddingService do
  let(:service) { described_class.new(account_id: 123) }
  let(:embedding_result) { instance_double(RubyLLM::Embedding, vectors: [0.1, 0.2, 0.3]) }

  before do
    upsert_installation_config('CAPTAIN_OPEN_AI_API_KEY', 'test-key')
    allow(Llm::Config).to receive(:initialize!)
  end

  describe '#get_embedding' do
    it 'delegates embedding generation to Llm::ApiClient' do
      expect(Llm::ApiClient).to receive(:embed).with(
        'hello',
        context: anything,
        model: LlmConstants::DEFAULT_EMBEDDING_MODEL,
        dimensions: described_class::VECTOR_DIMENSIONS,
        observability: hash_including(
          runtime_mode: 'captain_embedding',
          feature_name: 'embedding',
          account_id: 123
        )
      ).and_return(embedding_result)

      expect(service.get_embedding('hello')).to eq([0.1, 0.2, 0.3])
    end

    it 'passes explicit dimensions for text-embedding-3 models' do
      expect(Llm::ApiClient).to receive(:embed).with(
        'hello',
        context: anything,
        model: 'text-embedding-3-small',
        dimensions: described_class::VECTOR_DIMENSIONS,
        observability: hash_including(
          runtime_mode: 'captain_embedding',
          feature_name: 'embedding',
          account_id: 123
        )
      ).and_return(embedding_result)

      service.get_embedding('hello', model: 'text-embedding-3-small')
    end

    it 'wraps provider configuration errors as embedding errors' do
      allow(Llm::ApiClient).to receive(:embed).and_raise(RubyLLM::ConfigurationError, 'Missing configuration for OpenAI: openai_api_key')

      expect { service.get_embedding('hello') }
        .to raise_error(described_class::EmbeddingsError, /Failed to create an embedding/)
    end

    it 'does not silently use OpenAI embeddings when OpenRouter is primary and no embedding model is configured' do
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', '[REDACTED]')
      InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL')&.destroy!
      openrouter_service = described_class.new(account_id: 123)

      expect(Llm::ApiClient).not_to receive(:embed)
      expect { openrouter_service.get_embedding('hello') }
        .to raise_error(described_class::EmbeddingsUnavailableError, /OpenRouter does not expose/)
    end

    it 'allows an explicitly configured embedding model even when OpenRouter is primary' do
      upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', '[REDACTED]')
      upsert_installation_config('CAPTAIN_EMBEDDING_MODEL', 'text-embedding-3-small')
      explicit_service = described_class.new(account_id: 123)

      expect(Llm::ApiClient).to receive(:embed).with(
        'hello',
        context: anything,
        model: 'text-embedding-3-small',
        dimensions: described_class::VECTOR_DIMENSIONS,
        observability: hash_including(runtime_mode: 'captain_embedding')
      ).and_return(embedding_result)

      expect(explicit_service.get_embedding('hello')).to eq([0.1, 0.2, 0.3])
    end

    it 'returns an empty array when content is blank' do
      expect(Llm::ApiClient).not_to receive(:embed)

      expect(service.get_embedding('')).to eq([])
    end
  end
end
