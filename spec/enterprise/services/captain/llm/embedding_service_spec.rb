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
    it 'delegates OpenRouter embeddings to the native OpenRouter embedding client' do
      expect(Llm::ApiClient).not_to receive(:embed)
      expect(Llm::OpenRouterEmbeddingClient).to receive(:embed).with(
        'hello',
        hash_including(
          model: LlmConstants::DEFAULT_EMBEDDING_MODEL,
          dimensions: described_class::VECTOR_DIMENSIONS,
          api_key: 'test-openrouter-key'
        )
      ).and_return(openrouter_result)

      expect(service.get_embedding('hello')).to eq(openrouter_vector)
    end

    it 'passes the configured OpenRouter API base to the embedding client' do
      upsert_installation_config('CAPTAIN_OPENROUTER_ENDPOINT', 'https://openrouter.ai/api/v1/models')

      expect(Llm::OpenRouterEmbeddingClient).to receive(:embed).with(
        'hello',
        hash_including(api_base: 'https://openrouter.ai/api/v1/models')
      ).and_return(openrouter_result)

      expect(service.get_embedding('hello')).to eq(openrouter_vector)
    end

    it 'wraps OpenRouter client errors as embedding errors' do
      allow(Llm::OpenRouterEmbeddingClient).to receive(:embed)
        .and_raise(RubyLLM::Error, 'OpenRouter embedding failed: bad model')

      expect { service.get_embedding('hello') }
        .to raise_error(described_class::EmbeddingsError, /Failed to create an embedding: OpenRouter embedding failed: bad model/)
    end

    it 'wraps non-OpenRouter provider configuration errors as embedding errors' do
      allow(Llm::Config).to receive(:provider_for_model).and_call_original
      allow(Llm::Config).to receive(:provider_for_model).with(anything, account: anything).and_return('openai')
      allow(Llm::ApiClient).to receive(:embed).and_raise(RubyLLM::ConfigurationError, 'Missing configuration for OpenAI: openai_api_key')

      expect(Llm::OpenRouterEmbeddingClient).not_to receive(:embed)
      expect { service.get_embedding('hello', model: 'gpt-4.1') }
        .to raise_error(described_class::EmbeddingsError, /Failed to create an embedding/)
    end

    it 'raises unavailable when OpenRouter embedding key is not configured' do
      InstallationConfig.find_by(name: 'CAPTAIN_OPENROUTER_API_KEY')&.destroy!
      openrouter_service = described_class.new(account_id: 123)

      expect(Llm::ApiClient).not_to receive(:embed)
      expect(Llm::OpenRouterEmbeddingClient).not_to receive(:embed)
      expect { openrouter_service.get_embedding('hello') }
        .to raise_error(described_class::EmbeddingsUnavailableError, /OpenRouter embeddings are not configured/)
    end

    it 'returns an empty array when content is blank' do
      expect(Llm::ApiClient).not_to receive(:embed)
      expect(Llm::OpenRouterEmbeddingClient).not_to receive(:embed)

      expect(service.get_embedding('')).to eq([])
    end
  end
end
