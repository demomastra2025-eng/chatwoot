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

  it 'raises retryable embedding errors for records without embedding status' do
    response = create(:captain_assistant_response, account: account, assistant: assistant)
    service = instance_double(Captain::Llm::EmbeddingService)
    allow(service).to receive(:get_embedding).and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'temporary outage')
    allow(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(service)

    expect { described_class.perform_now(response, response.question) }
      .to raise_error(Captain::Llm::EmbeddingService::EmbeddingsError, 'temporary outage')
  end
end
