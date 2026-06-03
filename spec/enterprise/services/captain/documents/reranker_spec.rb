# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Documents::Reranker do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:document) { create(:captain_document, account: account, assistant: assistant) }
  let(:first_chunk) { create(:captain_document_chunk, account: account, assistant: assistant, document: document, content: 'Shipping policy') }
  let(:second_chunk) { create(:captain_document_chunk, account: account, assistant: assistant, document: document, content: 'Refund policy') }

  before do
    allow(Llm::Config).to receive(:model_for).with(feature: 'knowledge_rerank', account: account, fallback: nil).and_return('cohere/rerank-v3.5')
  end

  it 'reranks document chunks through the OpenRouter runtime and returns score trace' do
    rerank_result = Llm::OpenRouterRerankClient::Result.new(
      model: 'cohere/rerank-v3.5',
      results: [
        Llm::OpenRouterRerankClient::ResultItem.new(index: 1, relevance_score: 0.98),
        Llm::OpenRouterRerankClient::ResultItem.new(index: 0, relevance_score: 0.22)
      ]
    )

    expect(Llm::Runtime).to receive(:rerank).with(
      feature: :knowledge_rerank,
      account: account,
      model: 'cohere/rerank-v3.5',
      input: { query: 'refund', documents: ['Shipping policy', 'Refund policy'] },
      options: { top_n: 2 }
    ).and_return(rerank_result)

    result = described_class.new(account: account).call(query: 'refund', documents: [first_chunk, second_chunk], top_n: 2)

    expect(result.documents).to eq([second_chunk, first_chunk])
    expect(result.trace).to include(attempted: true, enabled: true, degraded: false, model: 'cohere/rerank-v3.5')
    expect(result.trace[:scores]).to contain_exactly(
      { document_chunk_id: second_chunk.id, relevance_score: 0.98 },
      { document_chunk_id: first_chunk.id, relevance_score: 0.22 }
    )
  end

  it 'keeps vector order when rerank is not configured' do
    allow(Llm::Config).to receive(:model_for).with(feature: 'knowledge_rerank', account: account, fallback: nil).and_return(nil)
    expect(Llm::Runtime).not_to receive(:rerank)

    result = described_class.new(account: account).call(query: 'refund', documents: [first_chunk, second_chunk], top_n: 1)

    expect(result.documents).to eq([first_chunk])
    expect(result.trace).to eq(attempted: false, enabled: false)
  end

  it 'keeps vector order and marks rerank degraded when OpenRouter rerank fails' do
    allow(Llm::Runtime).to receive(:rerank).and_raise(RubyLLM::Error, 'provider unavailable')

    result = described_class.new(account: account).call(query: 'refund', documents: [first_chunk, second_chunk], top_n: 2)

    expect(result.documents).to eq([first_chunk, second_chunk])
    expect(result.trace).to include(
      attempted: true,
      enabled: true,
      degraded: true,
      fallback_reason: 'rerank_unavailable',
      error_class: 'RubyLLM::Error'
    )
  end

  it 'bounds rerank calls and degrades when the timeout fires' do
    expect(Timeout).to receive(:timeout)
      .with(described_class::REQUEST_TIMEOUT_SECONDS)
      .and_raise(Timeout::Error, 'execution expired')

    result = described_class.new(account: account).call(query: 'refund', documents: [first_chunk, second_chunk], top_n: 2)

    expect(result.documents).to eq([first_chunk, second_chunk])
    expect(result.trace).to include(
      attempted: true,
      enabled: true,
      degraded: true,
      fallback_reason: 'rerank_unavailable',
      error_class: 'Timeout::Error'
    )
  end
end
