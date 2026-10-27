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

      expect(described_class.embedding_model).to eq('google/gemini-embedding-001')
      expect(Llm::Config.provider_for_model(described_class.embedding_model)).to eq('openrouter')
    end

    it 'follows the model stored by the platform, whatever it is' do
      upsert_installation_config('CAPTAIN_EMBEDDING_MODEL', 'text-embedding-3-large')

      expect(described_class.embedding_model).to eq('text-embedding-3-large')
    end
  end

  describe '.normalize' do
    it 'scales a vector to unit length and leaves a zero vector alone' do
      expect(described_class.normalize([3.0, 4.0])).to eq([0.6, 0.8])
      expect(described_class.normalize([0.0, 0.0])).to eq([0.0, 0.0])
    end
  end

  describe '.checksum' do
    it 'is the SHA-256 of the squished text, so that spacing does not make a new vector' do
      expect(described_class.checksum("Where  are\nyou?")).to eq(Digest::SHA256.hexdigest('Where are you?'))
      expect(described_class.checksum('Where are you?')).to eq(described_class.checksum(" Where are you? \n"))
      expect(described_class.checksum('Where are you?')).not_to eq(described_class.checksum('Where are we?'))
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

    it 'asks for 1536 numbers from the platform model, Gemini included, not only from OpenAI models' do
      expect(Llm::Runtime).to receive(:embed) do |**kwargs|
        expect(kwargs).to include(feature: :help_center_search, model: 'google/gemini-embedding-001', input: 'hello')
        expect(kwargs[:options]).to eq(dimensions: 1536, input_type: 'search_document')
        openrouter_result
      end

      expect(service.get_embedding('hello', model: 'google/gemini-embedding-001', input_type: 'search_document')).to eq(openrouter_vector)
    end

    it 'rejects an answer of a wrong size, whatever the runtime did' do
      expect(Llm::Runtime).to receive(:embed)
        .and_return(instance_double(Llm::OpenRouterEmbeddingClient::Result, vectors: [Array.new(3072, 0.1)]))

      expect { service.get_embedding('hello', model: 'google/gemini-embedding-001') }
        .to raise_error(described_class::EmbeddingsError, %r{google/gemini-embedding-001 returned 3072 dimensions, expected 1536})
    end

    it 'returns an empty array when content is blank' do
      expect(Llm::ApiClient).not_to receive(:embed)
      expect(Llm::OpenRouterEmbeddingClient).not_to receive(:embed)
      expect(Llm::Runtime).not_to receive(:embed)

      expect(service.get_embedding('')).to eq([])
    end
  end

  describe '#get_embeddings' do
    let(:second_vector) { Array.new(described_class::VECTOR_DIMENSIONS, 0.2) }

    def result_of(*vectors)
      instance_double(Llm::OpenRouterEmbeddingClient::Result, vectors: vectors)
    end

    it 'embeds many texts in one request and returns the vectors in the order of the texts' do
      expect(Llm::Runtime).to receive(:embed).once do |**kwargs|
        expect(kwargs).to include(model: 'google/gemini-embedding-001', input: %w[first second])
        expect(kwargs[:options]).to eq(dimensions: 1536, input_type: 'search_query')
        result_of(openrouter_vector, second_vector)
      end

      expect(service.get_embeddings(%w[first second], model: 'google/gemini-embedding-001', input_type: 'search_query'))
        .to eq([openrouter_vector, second_vector])
    end

    it 'sends one text the way a single embedding is sent' do
      expect(Llm::Runtime).to receive(:embed) { |**kwargs| expect(kwargs[:input]).to eq('only') }.and_return(openrouter_result)

      expect(service.get_embeddings(['only'], model: 'google/gemini-embedding-001')).to eq([openrouter_vector])
    end

    it 'splits a long list into requests of at most 64 texts, in order' do
      sizes = []
      allow(Llm::Runtime).to receive(:embed) do |**kwargs|
        sizes << kwargs[:input].size
        result_of(*Array.new(kwargs[:input].size) { openrouter_vector })
      end

      expect(service.get_embeddings(Array.new(130) { |index| "text #{index}" }, model: 'google/gemini-embedding-001').size).to eq(130)
      expect(sizes).to eq([64, 64, 2])
    end

    it 'splits a list whose characters pass the limit of a request' do
      sizes = []
      allow(Llm::Runtime).to receive(:embed) do |**kwargs|
        sizes << Array(kwargs[:input]).size
        result_of(*Array.new(Array(kwargs[:input]).size) { openrouter_vector })
      end

      service.get_embeddings(Array.new(3) { 'x' * 20_000 }, model: 'google/gemini-embedding-001')

      expect(sizes).to eq([2, 1])
    end

    it 'rejects a vector of a wrong size, a missing vector and a blank text' do
      allow(Llm::Runtime).to receive(:embed).and_return(result_of(openrouter_vector, Array.new(768, 0.1)))
      expect { service.get_embeddings(%w[a b]) }.to raise_error(described_class::EmbeddingsError, /returned 768 dimensions, expected 1536/)

      allow(Llm::Runtime).to receive(:embed).and_return(result_of(openrouter_vector))
      expect { service.get_embeddings(%w[a b]) }.to raise_error(described_class::EmbeddingsError, /did not include a vector/)

      expect { service.get_embeddings(['a', ' ']) }.to raise_error(ArgumentError, /must not be blank/)
    end

    it 'returns an empty list for an empty list and raises unavailable without a model or a key' do
      expect(service.get_embeddings([])).to eq([])
      expect { service.get_embeddings(['a'], model: nil) }.to raise_error(described_class::EmbeddingsUnavailableError)

      InstallationConfig.find_by(name: 'CAPTAIN_OPENROUTER_API_KEY')&.destroy!
      expect { described_class.new(account_id: 123).get_embeddings(['a'], model: 'google/gemini-embedding-001') }
        .to raise_error(described_class::EmbeddingsUnavailableError, /not configured/)
    end
  end

  describe 'against the OpenRouter endpoint' do
    let(:endpoint) { 'https://openrouter.ai/api/v1/embeddings' }
    let(:http_service) { described_class.new(account_id: create(:account).id) }

    def answer(*vectors)
      { status: 200, headers: { 'Content-Type' => 'application/json' },
        body: { model: 'google/gemini-embedding-001', usage: { prompt_tokens: 7 },
                data: vectors.each_with_index.map { |vector, index| { index: index, embedding: vector } } }.to_json }
    end

    it 'sends the Gemini model with dimensions 1536, the input type and the privacy rules, and takes the vectors back in order' do
      stub = stub_request(:post, endpoint).with do |request|
        body = JSON.parse(request.body)
        expect(body).to include('model' => 'google/gemini-embedding-001', 'input' => %w[one two], 'dimensions' => 1536,
                                'input_type' => 'search_query')
        expect(body['provider']).to include('data_collection' => 'deny')
        expect(body).not_to have_key('models')
      end.to_return(answer(openrouter_vector, openrouter_vector.map { |value| value * 2 }))

      vectors = http_service.get_embeddings(%w[one two], model: 'google/gemini-embedding-001', input_type: 'search_query')

      expect(stub).to have_been_requested.once
      expect(vectors.map(&:size)).to eq([1536, 1536])
    end

    it 'refuses the answer of a model that ignored the requested size' do
      stub_request(:post, endpoint).to_return(answer(Array.new(3072, 0.1)))

      expect { http_service.get_embedding('hello', model: 'google/gemini-embedding-001') }
        .to raise_error(described_class::EmbeddingsError, %r{returned 3072 dimensions for google/gemini-embedding-001, expected 1536})
    end
  end
end
