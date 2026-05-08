# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Llm::EmbeddingService do
  let(:service) { described_class.new(account_id: 123) }
  let(:embedding_result) { instance_double(RubyLLM::Embedding, vectors: [0.1, 0.2, 0.3]) }

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
    it 'uses OpenRouter embeddings for the default text embedding model' do
      expect(Llm::ApiClient).not_to receive(:embed)
      expect(service).to receive(:openrouter_embedding).with('hello', LlmConstants::DEFAULT_EMBEDDING_MODEL).and_return([0.1, 0.2, 0.3])

      expect(service.get_embedding('hello')).to eq([0.1, 0.2, 0.3])
    end

    it 'posts embedding requests to the OpenRouter embeddings API' do
      response = instance_double(Net::HTTPResponse, code: '200', message: 'OK', body: JSON.generate(data: [{ embedding: [0.1, 0.2, 0.3] }]))
      http = instance_double(Net::HTTP)
      captured_request = nil

      allow(http).to receive(:request) do |request|
        captured_request = request
        response
      end
      allow(Net::HTTP).to receive(:start).and_yield(http)

      expect(service.get_embedding('hello')).to eq([0.1, 0.2, 0.3])
      expect(captured_request.path).to eq('/api/v1/embeddings')
      expect(captured_request['Authorization']).to eq('Bearer test-openrouter-key')
      expect(JSON.parse(captured_request.body)).to include(
        'model' => 'text-embedding-3-small',
        'input' => 'hello',
        'dimensions' => described_class::VECTOR_DIMENSIONS
      )
    end

    it 'wraps OpenRouter embedding API errors' do
      response = instance_double(Net::HTTPResponse, code: '400', message: 'Bad Request', body: JSON.generate(error: { message: 'bad model' }))
      http = instance_double(Net::HTTP, request: response)
      allow(Net::HTTP).to receive(:start).and_yield(http)

      expect { service.get_embedding('hello') }
        .to raise_error(described_class::EmbeddingsError, /OpenRouter embedding failed: bad model/)
    end

    it 'wraps OpenRouter transport errors' do
      allow(Net::HTTP).to receive(:start).and_raise(OpenSSL::SSL::SSLError, 'certificate verify failed')

      expect { service.get_embedding('hello') }
        .to raise_error(described_class::EmbeddingsError, /OpenRouter embedding request failed: certificate verify failed/)
    end

    it 'wraps non-OpenRouter provider configuration errors as embedding errors' do
      allow(Llm::Config).to receive(:provider_for_model).and_call_original
      allow(Llm::Config).to receive(:provider_for_model).with(anything, account: anything).and_return('openai')
      allow(Llm::ApiClient).to receive(:embed).and_raise(RubyLLM::ConfigurationError, 'Missing configuration for OpenAI: openai_api_key')

      expect { service.get_embedding('hello', model: 'gpt-4.1') }
        .to raise_error(described_class::EmbeddingsError, /Failed to create an embedding/)
    end

    it 'raises unavailable when OpenRouter embedding key is not configured' do
      InstallationConfig.find_by(name: 'CAPTAIN_OPENROUTER_API_KEY')&.destroy!
      openrouter_service = described_class.new(account_id: 123)

      expect(Llm::ApiClient).not_to receive(:embed)
      expect { openrouter_service.get_embedding('hello') }
        .to raise_error(described_class::EmbeddingsUnavailableError, /OpenRouter embeddings are not configured/)
    end

    it 'returns an empty array when content is blank' do
      expect(Llm::ApiClient).not_to receive(:embed)

      expect(service.get_embedding('')).to eq([])
    end
  end
end
