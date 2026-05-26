require 'rails_helper'

RSpec.describe Captain::Tools::FaqLookupTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }
  let(:tool_context) { Struct.new(:state).new({}) }
  let(:document) { create(:captain_document, account: account, assistant: assistant) }
  let(:document_chunk) do
    document.document_chunks.create!(account: account, assistant: assistant, chunk_index: 0, content: 'Password reset source')
  end

  before do
    create(:captain_assistant_response, assistant: assistant, account: account, documentable: document, document_chunk: document_chunk,
                                        question: 'How to reset password?', answer: 'Click forgot password', status: 'approved')
    allow(Captain::DocumentChunk).to receive(:search).and_return(Captain::DocumentChunk.where(id: document_chunk.id))
  end

  it 'returns normalized faq payload' do
    payload = JSON.parse(tool.perform(tool_context, query: 'password reset'))

    expect(payload['query']).to eq('password reset')
    expect(payload['total_count']).to eq(1)
    expect(payload['matches'].first).to include('type' => 'document_chunk', 'answer' => 'Password reset source')
    expect(payload['matches'].first).to include('document_id' => document.id, 'document_chunk_id' => document_chunk.id)
    expect(payload['retrieval_trace']).to include(
      'strategy' => 'semantic_chunk',
      'degraded' => false,
      'semantic_attempted' => true,
      'match_count' => 1,
      'response_ids' => [],
      'document_ids' => [document.id],
      'document_chunk_ids' => [document_chunk.id]
    )
  end

  it 'falls back to exact/keyword FAQ lookup when semantic lookup is unavailable' do
    allow(Captain::DocumentChunk).to receive(:search)
      .and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'Failed to create an embedding')

    payload = JSON.parse(tool.perform(tool_context, query: 'reset password'))

    expect(payload).to include(
      'query' => 'reset password',
      'total_count' => 1,
      'lookup_strategy' => 'lexical'
    )
    expect(payload['retrieval_trace']).to include(
      'strategy' => 'lexical',
      'degraded' => true,
      'semantic_attempted' => true,
      'fallback_reason' => 'semantic_unavailable',
      'match_count' => 1
    )
    expect(payload).not_to have_key('error')
    expect(payload['matches'].first).to include(
      'question' => 'How to reset password?',
      'answer' => 'Click forgot password'
    )
  end

  it 'returns an empty lexical payload when embeddings are unavailable and no keyword matches' do
    allow(Captain::DocumentChunk).to receive(:search)
      .and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'Failed to create an embedding')

    payload = JSON.parse(tool.perform(tool_context, query: 'pricing'))

    expect(payload).to include(
      'query' => 'pricing',
      'total_count' => 0,
      'matches' => [],
      'lookup_strategy' => 'lexical'
    )
    expect(payload).not_to have_key('error')
  end

  it 'can skip semantic lookup for realtime voice calls' do
    expect(Captain::DocumentChunk).not_to receive(:search)

    payload = JSON.parse(tool.perform(tool_context, query: 'reset password', semantic: false))

    expect(payload).to include(
      'query' => 'reset password',
      'total_count' => 1,
      'lookup_strategy' => 'lexical'
    )
    expect(payload['retrieval_trace']).to include(
      'strategy' => 'lexical',
      'degraded' => false,
      'semantic_attempted' => false,
      'match_count' => 1
    )
  end
end
