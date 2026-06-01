# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Llm::EmbeddingService do
  let(:service) { described_class.new(account_id: 123) }
  let(:openrouter_vector) { Array.new(described_class::VECTOR_DIMENSIONS, 0.1) }
  let(:openrouter_result) { instance_double(Llm::OpenRouterEmbeddingClient::Result, vectors: [openrouter_vector]) }

  before do
    upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'test-openrouter-key')
    allow(Llm::Config).to receive(:initialize!)
  end

  describe '.embedding_model' do
    it 'uses the help center search default with OpenRouter when no explicit embedding model is stored' do
      InstallationConfig.find_by(name: 'CAPTAIN_EMBEDDING_MODEL')&.destroy!

      expect(described_class.embedding_model).to eq('text-embedding-3-small')
      expect(Llm::Config.provider_for_model(described_class.embedding_model)).to eq('openrouter')
    end
  end

  describe '#get_embedding' do
    it 'delegates OpenRouter embeddings through the LLM runtime facade' do
      expect(Llm::ApiClient).not_to receive(:embed)
      expect(Llm::OpenRouterEmbeddingClient).not_to receive(:embed)
      expect(Llm::Runtime).to receive(:embed) do |**kwargs|
        expect(kwargs).to include(
          feature: :help_center_search,
          model: LlmConstants::DEFAULT_EMBEDDING_MODEL,
          input: 'hello',
          options: {
            dimensions: described_class::VECTOR_DIMENSIONS,
            input_type: described_class::SEARCH_QUERY_INPUT_TYPE
          }
        )
        expect(kwargs[:observability]).to include(
          provider: 'openrouter',
          runtime_mode: 'captain_embedding',
          feature_name: 'embedding'
        )
        openrouter_result
      end

      expect(service.get_embedding('hello', input_type: described_class::SEARCH_QUERY_INPUT_TYPE)).to eq(openrouter_vector)
    end

    it 'omits OpenRouter input_type when no type is provided for compatibility' do
      expect(Llm::Runtime).to receive(:embed) do |**kwargs|
        expect(kwargs[:options]).to eq(dimensions: described_class::VECTOR_DIMENSIONS)
        expect(kwargs[:observability]).not_to include(:input_type)
        openrouter_result
      end

      expect(service.get_embedding('hello')).to eq(openrouter_vector)
    end

    it 'rejects unsupported embedding input types before provider calls' do
      expect(Llm::Runtime).not_to receive(:embed)

      expect { service.get_embedding('hello', input_type: 'classification') }
        .to raise_error(ArgumentError, /Unsupported embedding input_type: classification/)
    end

    it 'keeps vector dimension validation at the service boundary after runtime delegation' do
      invalid_result = instance_double(Llm::OpenRouterEmbeddingClient::Result, vectors: [nil])

      expect(Llm::Runtime).to receive(:embed).and_return(invalid_result)

      expect { service.get_embedding('hello') }
        .to raise_error(described_class::EmbeddingsError, /did not include a vector/)
    end

    it 'wraps OpenRouter client errors as embedding errors' do
      allow(Llm::Runtime).to receive(:embed)
        .and_raise(RubyLLM::Error, 'OpenRouter embedding failed: bad model')

      expect { service.get_embedding('hello') }
        .to raise_error(described_class::EmbeddingsError, /Failed to create an embedding: OpenRouter embedding failed: bad model/)
    end

    it 'does not fall back to direct provider embedding APIs for legacy model ids' do
      allow(Llm::Config).to receive(:provider_for_model).and_call_original
      allow(Llm::Config).to receive(:provider_for_model).with(anything, account: anything).and_return('openai')
      allow(Llm::Runtime).to receive(:embed).and_raise(RubyLLM::ConfigurationError, 'OpenRouter API key is not configured')

      expect(Llm::ApiClient).not_to receive(:embed)
      expect(Llm::OpenRouterEmbeddingClient).not_to receive(:embed)
      expect { service.get_embedding('hello', model: 'gpt-4.1') }
        .to raise_error(described_class::EmbeddingsError, /Failed to create an embedding/)
    end

    it 'raises unavailable when OpenRouter embedding key is not configured' do
      InstallationConfig.find_by(name: 'CAPTAIN_OPENROUTER_API_KEY')&.destroy!
      openrouter_service = described_class.new(account_id: 123)

      expect(Llm::ApiClient).not_to receive(:embed)
      expect(Llm::OpenRouterEmbeddingClient).not_to receive(:embed)
      expect(Llm::Runtime).not_to receive(:embed)
      expect { openrouter_service.get_embedding('hello') }
        .to raise_error(described_class::EmbeddingsUnavailableError, /OpenRouter embeddings are not configured/)
    end

    it 'returns an empty array when content is blank' do
      expect(Llm::ApiClient).not_to receive(:embed)
      expect(Llm::OpenRouterEmbeddingClient).not_to receive(:embed)
      expect(Llm::Runtime).not_to receive(:embed)

      expect(service.get_embedding('')).to eq([])
    end
  end
end
