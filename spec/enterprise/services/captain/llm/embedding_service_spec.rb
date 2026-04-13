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

    it 'returns an empty array when content is blank' do
      expect(Llm::ApiClient).not_to receive(:embed)

      expect(service.get_embedding('')).to eq([])
    end
  end
end
