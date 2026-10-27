require 'rails_helper'

RSpec.describe Captain::Llm::UpdateEmbeddingJob do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:document) { create(:captain_document, account: account, assistant: assistant) }
  let(:chunk) { create(:captain_document_chunk, account: account, assistant: assistant, document: document, content: 'Knowledge chunk') }

  it 'marks document chunk embeddings as indexed after update', :aggregate_failures do
    embedding = Array.new(Captain::Llm::EmbeddingService::VECTOR_DIMENSIONS, 0.2)
    embedding_service = instance_double(Captain::Llm::EmbeddingService)
    allow(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(embedding_service)
    allow(embedding_service).to receive(:embedding_model).and_return('openai/text-embedding-3-small')
    expect(embedding_service).to receive(:get_embedding)
      .with(chunk.content, input_type: Captain::Llm::EmbeddingService::SEARCH_DOCUMENT_INPUT_TYPE)
      .and_return(embedding)
    logged_messages = []
    allow(Rails.logger).to receive(:info) { |message| logged_messages << message.to_s }

    described_class.perform_now(chunk, chunk.content)

    log_message = logged_messages.find { |message| message.include?('[Captain::Llm::UpdateEmbeddingJob] Indexed Captain embedding') }
    expect(log_message).to include('openai/text-embedding-3-small')
    expect(log_message).to include('search_document')
    expect(log_message).to include('vector_dimensions: 1536')
    expect(log_message).to include('chunk_count: 1')
    expect(log_message).not_to include(chunk.content)

    expect(chunk.reload).to have_attributes(
      embedding_status: 'indexed',
      embedding_error: nil
    )
    expect(chunk.embedding_updated_at).to be_present
  end

  describe 'which model made the vector' do
    let(:embedding) { Array.new(Captain::Llm::EmbeddingService::VECTOR_DIMENSIONS, 0.2) }
    let(:embedding_service) { instance_double(Captain::Llm::EmbeddingService, embedding_model: 'google/gemini-embedding-001') }
    let(:response) { create(:captain_assistant_response, account: account, assistant: assistant, question: 'Where?', answer: 'Here') }
    let(:content) { 'Where?: Here' }

    before { allow(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(embedding_service) }

    it 'stores the model name and the checksum of the text with the vector of an FAQ' do
      allow(embedding_service).to receive(:get_embedding).and_return(embedding)

      described_class.perform_now(response, content)

      expect(response.reload).to have_attributes(embedding_model: 'google/gemini-embedding-001',
                                                 embedding_checksum: Captain::Llm::EmbeddingService.checksum(content))
    end

    it 'stores the model name with the vector of a knowledge chunk' do
      allow(embedding_service).to receive(:get_embedding).and_return(embedding)

      described_class.perform_now(chunk, chunk.content)

      expect(chunk.reload.embedding_model).to eq('google/gemini-embedding-001')
    end

    it 'does not call the model for an FAQ whose text and model are those of its vector' do
      response.update_columns(embedding_model: 'google/gemini-embedding-001', embedding_checksum: Captain::Llm::EmbeddingService.checksum(content)) # rubocop:disable Rails/SkipsModelValidations
      expect(embedding_service).not_to receive(:get_embedding)

      described_class.perform_now(response, content)
    end

    it 'calls the model again when the text changed or the vector was made by another model' do
      allow(embedding_service).to receive(:get_embedding).and_return(embedding)
      response.update_columns(embedding_model: 'google/gemini-embedding-001', # rubocop:disable Rails/SkipsModelValidations
                              embedding_checksum: Captain::Llm::EmbeddingService.checksum('Old: text'))
      described_class.perform_now(response, content)
      expect(embedding_service).to have_received(:get_embedding).once

      response.update_columns(embedding_model: 'text-embedding-3-large') # rubocop:disable Rails/SkipsModelValidations
      described_class.perform_now(response, content)
      expect(embedding_service).to have_received(:get_embedding).twice
      expect(response.reload.embedding_model).to eq('google/gemini-embedding-001')
    end

    it 'ignores spacing when it compares the text with the checksum' do
      response.update_columns(embedding_model: 'google/gemini-embedding-001', embedding_checksum: Captain::Llm::EmbeddingService.checksum(content)) # rubocop:disable Rails/SkipsModelValidations
      expect(embedding_service).not_to receive(:get_embedding)

      described_class.perform_now(response, "Where?:   Here\n")
    end
  end

  it 'does not store an embedding for stale content' do
    embedding = Array.new(Captain::Llm::EmbeddingService::VECTOR_DIMENSIONS, 0.2)
    service = instance_double(Captain::Llm::EmbeddingService)
    original_content = chunk.content
    allow(service).to receive(:get_embedding) do
      chunk.update!(content: 'Updated knowledge chunk')
      embedding
    end
    allow(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(service)

    described_class.perform_now(chunk, original_content)

    expect(chunk.reload.content).to eq('Updated knowledge chunk')
    expect(chunk.embedding_status).not_to eq('indexed')
  end

  it 'marks document chunk embeddings as failed when embeddings are unavailable' do
    service = instance_double(Captain::Llm::EmbeddingService)
    allow(service).to receive(:get_embedding).and_raise(Captain::Llm::EmbeddingService::EmbeddingsUnavailableError, 'not configured')
    allow(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(service)
    chunk
    expect(described_class).not_to receive(:perform_later)

    described_class.perform_now(chunk, chunk.content)

    expect(chunk.reload.embedding_status).to eq('failed')
    expect(chunk.embedding_error).to include('not configured')
  end

  it 'does not mark updated content as failed for a stale embedding request' do
    service = instance_double(Captain::Llm::EmbeddingService)
    original_content = chunk.content
    allow(service).to receive(:get_embedding) do
      chunk.update!(content: 'Updated knowledge chunk')
      raise Captain::Llm::EmbeddingService::EmbeddingsUnavailableError, 'not configured'
    end
    allow(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(service)

    described_class.perform_now(chunk, original_content)

    expect(chunk.reload.content).to eq('Updated knowledge chunk')
    expect(chunk.embedding_status).not_to eq('failed')
    expect(chunk.embedding_error).to be_blank
  end

  it 'does not retry a stale embedding error for records without embedding status' do
    response = create(:captain_assistant_response, account: account, assistant: assistant)
    service = instance_double(Captain::Llm::EmbeddingService)
    original_content = "#{response.question}: #{response.answer}"
    allow(service).to receive(:get_embedding) do
      response.update!(answer: 'Updated answer')
      raise Captain::Llm::EmbeddingService::EmbeddingsError, 'temporary outage'
    end
    allow(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(service)

    expect { described_class.perform_now(response, original_content) }.not_to raise_error
    expect(response.reload.answer).to eq('Updated answer')
  end

  it 'raises retryable embedding errors for records without embedding status' do
    response = create(:captain_assistant_response, account: account, assistant: assistant)
    service = instance_double(Captain::Llm::EmbeddingService)
    allow(service).to receive(:get_embedding).and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'temporary outage')
    allow(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(service)
    content = "#{response.question}: #{response.answer}"

    expect { described_class.perform_now(response, content) }
      .to raise_error(Captain::Llm::EmbeddingService::EmbeddingsError, 'temporary outage')
  end
end
