require 'rails_helper'

RSpec.describe Captain::Tools::SearchDocumentationService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant) }

  before do
    translate_service = instance_double(Captain::Llm::TranslateQueryService)
    allow(Captain::Llm::TranslateQueryService).to receive(:new).with(account: account).and_return(translate_service)
    allow(translate_service).to receive(:translate).and_return('visibilityscope')
  end

  it 'shares general chunks but hides another assistant personal chunks' do
    other_assistant = create(:captain_assistant, account: account)
    general_document = create(:captain_document, account: account, assistant: other_assistant, visibility: :general)
    personal_document = create(:captain_document, account: account, assistant: other_assistant, visibility: :personal)
    general_chunk = general_document.document_chunks.create!(
      account: account,
      assistant: other_assistant,
      chunk_index: 0,
      content: 'Shared documentation source'
    )
    personal_chunk = personal_document.document_chunks.create!(
      account: account,
      assistant: other_assistant,
      chunk_index: 0,
      content: 'Private documentation source'
    )
    allow(Captain::DocumentChunk).to receive(:search).and_return(Captain::DocumentChunk.where(id: [general_chunk.id, personal_chunk.id]))

    result = service.execute(query: 'visibilityscope')

    expect(result).to include('Shared documentation source')
    expect(result).not_to include('Private documentation source')
  end

  it 'shares general FAQ entries but hides another assistant personal entries during lexical fallback' do
    other_assistant = create(:captain_assistant, account: account)
    create(
      :captain_assistant_response,
      assistant: other_assistant,
      account: account,
      question: 'visibilityscope shared',
      answer: 'Shared documentation answer',
      visibility: :general,
      status: :approved
    )
    create(
      :captain_assistant_response,
      assistant: other_assistant,
      account: account,
      question: 'visibilityscope private',
      answer: 'Private documentation answer',
      visibility: :personal,
      status: :approved
    )
    allow(Captain::DocumentChunk).to receive(:search).and_return(Captain::DocumentChunk.none)

    result = service.execute(query: 'visibilityscope')

    expect(result).to include('Shared documentation answer')
    expect(result).not_to include('Private documentation answer')
  end

  it 'degrades to lexical fallback when semantic documentation lookup times out' do
    create(
      :captain_assistant_response,
      assistant: assistant,
      account: account,
      question: 'visibilityscope timeout',
      answer: 'Timeout fallback answer',
      status: :approved
    )
    allow(Captain::DocumentChunk).to receive(:search).and_raise(Timeout::Error, 'execution expired')

    result = service.execute(query: 'visibilityscope')

    expect(result).to include('Timeout fallback answer')
    expect(result).not_to include('temporarily unavailable')
  end

  it 'bounds semantic documentation lookup and degrades to lexical fallback on timeout' do
    create(
      :captain_assistant_response,
      assistant: assistant,
      account: account,
      question: 'visibilityscope bounded timeout',
      answer: 'Bounded timeout fallback answer',
      status: :approved
    )
    allow(Timeout).to receive(:timeout).and_call_original
    expect(Timeout).to receive(:timeout)
      .with(described_class::SEMANTIC_LOOKUP_TIMEOUT_SECONDS)
      .and_raise(Timeout::Error, 'execution expired')

    result = service.execute(query: 'visibilityscope')

    expect(result).to include('Bounded timeout fallback answer')
    expect(result).not_to include('temporarily unavailable')
  end

  it 'returns structured degraded metadata when semantic documentation lookup times out' do
    create(
      :captain_assistant_response,
      assistant: assistant,
      account: account,
      question: 'visibilityscope structured timeout',
      answer: 'Structured timeout fallback answer',
      status: :approved
    )
    allow(Captain::DocumentChunk).to receive(:search).and_raise(Timeout::Error, 'execution expired')

    payload = JSON.parse(service.execute(query: 'visibilityscope'))

    expect(payload).to include(
      'query' => 'visibilityscope',
      'translated_query' => 'visibilityscope',
      'lookup_strategy' => 'lexical',
      'total_count' => 1
    )
    expect(payload['matches'].first).to include('answer' => 'Structured timeout fallback answer')
    expect(payload['retrieval_trace']).to include(
      'strategy' => 'lexical',
      'degraded' => true,
      'semantic_attempted' => true,
      'fallback_reason' => 'semantic_timeout',
      'match_count' => 1
    )
  end

  it 'falls back to lexical document chunk matches when embeddings are unavailable' do
    document = create(:captain_document, account: account, assistant: assistant)
    chunk = document.document_chunks.create!(
      account: account,
      assistant: assistant,
      chunk_index: 0,
      content: 'Chunkonly troubleshooting guide'
    )
    allow(Captain::DocumentChunk).to receive(:search)
      .and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'Failed to create an embedding')

    payload = JSON.parse(service.execute(query: 'chunkonly'))

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload.dig('retrieval_trace', 'document_chunk_ids')).to contain_exactly(chunk.id)
    expect(payload['matches'].first).to include(
      'type' => 'document_chunk',
      'answer' => 'Chunkonly troubleshooting guide'
    )
  end

  it 'uses a total lookup budget around translation and semantic lookup' do
    create(
      :captain_assistant_response,
      assistant: assistant,
      account: account,
      question: 'visibilityscope total timeout',
      answer: 'Total timeout fallback answer',
      status: :approved
    )
    allow(Timeout).to receive(:timeout).and_call_original
    expect(Timeout).to receive(:timeout)
      .with(described_class::TOTAL_LOOKUP_TIMEOUT_SECONDS, described_class::TotalLookupTimeout)
      .and_raise(described_class::TotalLookupTimeout, 'execution expired')

    payload = JSON.parse(service.execute(query: 'visibilityscope'))

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload['retrieval_trace']).to include('degraded' => true, 'fallback_reason' => 'lookup_timeout')
    expect(payload['matches'].first).to include('answer' => 'Total timeout fallback answer')
  end
end
