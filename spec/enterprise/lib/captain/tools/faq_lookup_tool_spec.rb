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
  let(:faq_response) do
    create(:captain_assistant_response, assistant: assistant, account: account, documentable: document, document_chunk: document_chunk,
                                        question: 'How to reset password?', answer: 'Click forgot password', status: 'approved')
  end

  before do
    faq_response
    scored_response = Captain::AssistantResponse.select('captain_assistant_responses.*, 0.1 AS neighbor_distance').where(id: faq_response.id)
    allow(Captain::AssistantResponse).to receive(:search).and_return(scored_response)
  end

  # The full payload of a lookup, with the retrieval trace: what the answer cache stores and what staff debug with. The model reads
  # only the compact answer that #perform builds from it (see 'the answer the model reads').
  def lookup_payload(query, **)
    tool.send(:lookup_payload, query: query, **)
  end

  it 'returns normalized faq payload' do
    payload = lookup_payload('password reset')

    expect(payload['query']).to eq('password reset')
    expect(payload['total_count']).to eq(1)
    expect(payload['matches'].first).to include(
      'type' => 'faq_response',
      'answer' => 'Click forgot password',
      'score' => 0.9,
      'relevance_threshold' => 0.7,
      'relevance_threshold_passed' => true
    )
    expect(payload['matches'].first).to include('id' => faq_response.id, 'document_chunk_id' => document_chunk.id)
    expect(payload['retrieval_trace']).to include(
      'strategy' => 'semantic_faq',
      'degraded' => false,
      'semantic_attempted' => true,
      'match_count' => 1,
      'response_ids' => [faq_response.id],
      'document_ids' => [document.id],
      'document_chunk_ids' => [document_chunk.id]
    )
  end

  it 'serves repeated semantic lookups from the answer cache' do
    scored_response = Captain::AssistantResponse.select('captain_assistant_responses.*, 0.1 AS neighbor_distance').where(id: faq_response.id)
    expect(Captain::AssistantResponse).to receive(:search).once.and_return(scored_response)

    first_payload = lookup_payload('password reset')
    second_payload = lookup_payload(' password   reset ')

    expect(first_payload.dig('retrieval_trace', 'answer_cache')).to include('hit' => false, 'stored' => true)
    expect(second_payload.dig('retrieval_trace', 'answer_cache')).to include(
      'enabled' => true,
      'hit' => true,
      'match' => 'exact',
      'hit_count' => 1
    )
    expect(second_payload['query']).to eq(' password   reset ')
    expect(second_payload['matches'].first).to include('document_chunk_id' => document_chunk.id)
  end

  it 'rejects a moderate-similarity candidate (distance <= 0.62) when morphological corroboration fails' do
    therapist_faq = create(
      :captain_assistant_response,
      assistant: assistant,
      account: account,
      question: 'Принимает ли терапевт?',
      answer: 'Да, терапевт принимает ежедневно.',
      status: 'approved'
    )
    scored = Captain::AssistantResponse.select('captain_assistant_responses.*, 0.48 AS neighbor_distance').where(id: therapist_faq.id)
    allow(Captain::AssistantResponse).to receive(:search).and_return(scored)

    payload = lookup_payload('стоимость приема терапевта')

    expect(payload).to include(
      'total_count' => 0,
      'result' => 'not_found',
      'lookup_strategy' => 'semantic_faq'
    )
    expect(payload['matches']).to be_empty
    expect(payload.dig('retrieval_trace', 'no_match_reason')).to eq('relevance_threshold_not_met')
    expect(payload.dig('retrieval_trace', 'relevance_check', 'corroboration', 'passed')).to be(false)
    expect(Captain::KnowledgeAnswerCacheEntry.count).to eq(0)
  end

  it 'returns corroborated_faq without caching when morphological corroboration rescues a moderate candidate' do
    therapist_faq = create(
      :captain_assistant_response,
      assistant: assistant,
      account: account,
      question: 'Принимает ли терапевт?',
      answer: 'Да, терапевт принимает ежедневно.',
      status: 'approved'
    )
    scored = Captain::AssistantResponse.select('captain_assistant_responses.*, 0.48 AS neighbor_distance').where(id: therapist_faq.id)
    allow(Captain::AssistantResponse).to receive(:search).and_return(scored)

    payload = lookup_payload('хочу к терапевту')

    expect(payload).to include(
      'total_count' => 1,
      'result' => 'found',
      'lookup_strategy' => 'corroborated_faq'
    )
    expect(payload['matches'].first).to include(
      'id' => therapist_faq.id,
      'question_corroboration_passed' => true,
      'relevance_selected' => true
    )
    expect(Captain::KnowledgeAnswerCacheEntry.count).to eq(0)
  end

  it 'does not expose a semantic candidate outside the relevance threshold' do
    faq_response.define_singleton_method(:neighbor_distance) { 0.9 }
    allow(Captain::AssistantResponse).to receive(:search).and_return([faq_response])

    payload = lookup_payload('unrelated phrase')

    expect(payload).to include(
      'total_count' => 0,
      'result' => 'not_found',
      'message' => 'No relevant FAQ result found',
      'lookup_strategy' => 'semantic_faq'
    )
    expect(payload['matches']).to be_empty
    expect(payload['retrieval_trace']).to include(
      'degraded' => false,
      'no_match_reason' => 'relevance_threshold_not_met',
      'match_count' => 0
    )
    expect(payload.dig('retrieval_trace', 'relevance_check')).to include(
      'metric' => 'cosine_similarity',
      'threshold' => 0.7,
      'best_score' => 0.1,
      'candidate_count' => 1,
      'passed' => false
    )
  end

  it 'falls back to exact/keyword FAQ lookup when semantic lookup is unavailable' do
    allow(Captain::AssistantResponse).to receive(:search)
      .and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'Failed to create an embedding')

    payload = lookup_payload('reset password')

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
    allow(Captain::AssistantResponse).to receive(:search)
      .and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'Failed to create an embedding')

    payload = lookup_payload('pricing')

    expect(payload).to include(
      'query' => 'pricing',
      'total_count' => 0,
      'matches' => [],
      'lookup_strategy' => 'lexical'
    )
    expect(payload).not_to have_key('error')
  end

  it 'marks semantic lookup as not configured when embeddings are not configured' do
    allow(Captain::AssistantResponse).to receive(:search)
      .and_raise(Captain::Llm::EmbeddingService::EmbeddingsUnavailableError, 'OpenRouter embeddings are not configured.')

    payload = lookup_payload('reset password')

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload['retrieval_trace']).to include(
      'degraded' => true,
      'fallback_reason' => 'semantic_not_configured',
      'match_count' => 1
    )
    expect(payload['matches'].first).to include('answer' => 'Click forgot password')
  end

  it 'degrades to lexical lookup when semantic lookup times out' do
    allow(Captain::AssistantResponse).to receive(:search).and_raise(Timeout::Error, 'execution expired')

    payload = lookup_payload('reset password')

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload['retrieval_trace']).to include(
      'degraded' => true,
      'fallback_reason' => 'semantic_timeout',
      'match_count' => 1
    )
    expect(payload['matches'].first).to include('answer' => 'Click forgot password')
  end

  it 'bounds semantic lookup and returns lexical results when the timeout fires' do
    allow(Timeout).to receive(:timeout).and_call_original
    expect(Timeout).to receive(:timeout)
      .with(described_class::SEMANTIC_LOOKUP_TIMEOUT_SECONDS)
      .and_raise(Timeout::Error, 'execution expired')

    payload = lookup_payload('reset password')

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload['retrieval_trace']).to include(
      'degraded' => true,
      'fallback_reason' => 'semantic_timeout',
      'match_count' => 1
    )
    expect(payload['matches'].first).to include('answer' => 'Click forgot password')
  end

  it 'bounds answer-cache reads and returns lexical results when cache lookup times out' do
    allow(Timeout).to receive(:timeout).and_call_original
    expect(Timeout).to receive(:timeout)
      .with(described_class::CACHE_FETCH_TIMEOUT_SECONDS)
      .and_raise(Timeout::Error, 'execution expired')

    payload = lookup_payload('reset password')

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload['retrieval_trace']).to include(
      'degraded' => true,
      'fallback_reason' => 'semantic_timeout',
      'match_count' => 1
    )
    expect(payload['matches'].first).to include('answer' => 'Click forgot password')
  end

  it 'uses a total lookup budget around cache and semantic lookup' do
    allow(Timeout).to receive(:timeout).and_call_original
    expect(Timeout).to receive(:timeout)
      .with(described_class::TOTAL_LOOKUP_TIMEOUT_SECONDS, described_class::TotalLookupTimeout)
      .and_raise(described_class::TotalLookupTimeout, 'execution expired')

    payload = lookup_payload('reset password')

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload['retrieval_trace']).to include(
      'degraded' => true,
      'fallback_reason' => 'lookup_timeout',
      'match_count' => 1
    )
    expect(payload['matches'].first).to include('answer' => 'Click forgot password')
  end

  it 'falls back to lexical document chunks when semantic lookup is unavailable' do
    chunk_only_document = create(:captain_document, account: account, assistant: assistant)
    chunk_only = chunk_only_document.document_chunks.create!(
      account: account,
      assistant: assistant,
      chunk_index: 0,
      content: 'Chunkonly recovery source'
    )
    allow(Captain::AssistantResponse).to receive(:search)
      .and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'Failed to create an embedding')

    payload = lookup_payload('chunkonly')

    expect(payload['lookup_strategy']).to eq('lexical')
    expect(payload.dig('retrieval_trace', 'document_chunk_ids')).to contain_exactly(chunk_only.id)
    expect(payload['matches'].first).to include(
      'type' => 'document_chunk',
      'answer' => 'Chunkonly recovery source'
    )
  end

  it 'can skip semantic lookup for realtime voice calls' do
    expect(Captain::AssistantResponse).not_to receive(:search)

    payload = lookup_payload('reset password', semantic: false)

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

  it 'requests semantic FAQ results in the current assistant visibility scope' do
    other_assistant = create(:captain_assistant, account: account)
    general_response = create(
      :captain_assistant_response,
      account: account,
      assistant: other_assistant,
      visibility: :general,
      question: 'Shared account recovery',
      answer: 'Shared account recovery source'
    )
    expect(Captain::AssistantResponse).to receive(:search).with(
      'account recovery',
      account_id: account.id,
      assistant_id: assistant.id,
      limit: 5
    ).and_return(
      Captain::AssistantResponse.select('captain_assistant_responses.*, 0.1 AS neighbor_distance').where(id: general_response.id)
    )

    payload = lookup_payload('account recovery')

    expect(payload.dig('retrieval_trace', 'response_ids')).to contain_exactly(general_response.id)
    expect(payload['matches'].map { |match| match['answer'] }).to contain_exactly('Shared account recovery source')
  end

  it 'returns an exact FAQ before cache and semantic lookup even when it has no embedding' do
    allow(Captain::Llm::UpdateEmbeddingJob).to receive(:perform_later)
    exact = create(
      :captain_assistant_response,
      account: account,
      assistant: nil,
      question: 'Что такое ADAMANT CLUB?',
      answer: 'Закрытый бизнес-клуб.',
      embedding: nil,
      created_at: 1.day.ago
    )
    expect(exact.embedding).to be_nil
    create(
      :captain_assistant_response,
      account: account,
      assistant: nil,
      question: 'Кто основатель клуба?',
      answer: 'Основатель ADAMANT CLUB.',
      embedding: Array.new(Captain::Llm::EmbeddingService::VECTOR_DIMENSIONS, 0.1),
      created_at: Time.current
    )
    expect(Captain::Knowledge::AnswerCache).not_to receive(:new)
    expect(Captain::AssistantResponse).not_to receive(:search)

    payload = lookup_payload('Что такое ADAMANT CLUB?')

    expect(payload['lookup_strategy']).to eq('lexical_exact')
    expect(payload['matches'].first).to include('id' => exact.id, 'answer' => 'Закрытый бизнес-клуб.')
  end

  describe 'the answer the model reads' do
    def knowledge_graph
      {
        corroborated: true,
        matched_nodes: Array.new(3) { |i| { id: i + 1, name: "Узел #{i}", node_type: 'service', attributes: { price: 5000 } } },
        connected_nodes: Array.new(4) { |i| { id: i + 10, name: "Связанный #{i}", node_type: 'doctor' } },
        edges: Array.new(4) { |i| { from: 1, to: i + 10, relation_type: 'offered_by' } },
        verified_facts: Array.new(3) { |i| { fact: "Факт #{i}", response_id: i } }
      }
    end

    it 'holds the result and, for each match, the question, the answer and the score, on one line' do
      output = tool.perform(tool_context, query: 'password reset')

      expect(output).not_to include("\n")
      expect(JSON.parse(output)).to eq(
        'result' => 'found',
        'matches' => [{ 'question' => 'How to reset password?', 'answer' => 'Click forgot password', 'score' => 0.9 }]
      )
    end

    it 'leaves out the retrieval trace, the knowledge graph and the bookkeeping fields of a match' do
      allow(tool).to receive(:knowledge_graph_payload_for).and_return(knowledge_graph)

      expect(lookup_payload('password reset')).to include('knowledge_graph', 'retrieval_trace')
      output = tool.perform(tool_context, query: 'password reset')

      expect(output).not_to match(/retrieval_trace|knowledge_graph|document_chunk_id|created_at|updated_at|relevance_threshold|lookup_strategy/)
    end

    it 'keeps the full answer, with its trace, for the realtime voice agent' do
      payload = JSON.parse(tool.perform(tool_context, query: 'reset password', voice_realtime: true))

      expect(payload).to include('lookup_strategy' => 'lexical_voice_realtime', 'total_count' => 1)
      expect(payload['retrieval_trace']).to include('strategy' => 'lexical_voice_realtime', 'fallback_reason' => 'voice_realtime_fast_path')
      expect(payload['matches'].first).to include('answer' => 'Click forgot password', 'document_chunk_id' => document_chunk.id)
    end

    it 'says not_found with its message and no matches' do
      allow(Captain::AssistantResponse).to receive(:search).and_return([])

      expect(JSON.parse(tool.perform(tool_context, query: 'unrelated phrase'))).to eq(
        'result' => 'not_found', 'message' => 'No relevant FAQ result found'
      )
    end

    it 'gives an exact FAQ match the score 1' do
      create(:captain_assistant_response, assistant: assistant, account: account, question: 'Что такое ADAMANT CLUB?',
                                          answer: 'Закрытый бизнес-клуб.', status: 'approved')

      match = JSON.parse(tool.perform(tool_context, query: 'Что такое ADAMANT CLUB?'))['matches'].first

      expect(match).to eq('question' => 'Что такое ADAMANT CLUB?', 'answer' => 'Закрытый бизнес-клуб.', 'score' => 1.0)
    end

    it 'keeps the fact that the lookup ran degraded in the run context, where the handoff and the outcome facts read it' do
      allow(Captain::AssistantResponse).to receive(:search).and_raise(Timeout::Error, 'execution expired')
      context = {}
      run_context = Struct.new(:state, :context).new({}, context)

      output = JSON.parse(tool.perform(run_context, query: 'pricing'))

      expect(output).to eq('result' => 'not_found', 'message' => 'No relevant FAQ result found')
      expect(context[:captain_faq_outcome]).to eq(assistant_id: assistant.id, result: 'not_found', unavailable: true)
    end

    it 'is a small fraction of the debugging payload for five long answers with a knowledge graph' do
      responses = Array.new(5) do |index|
        create(:captain_assistant_response, assistant: assistant, account: account, documentable: document, status: 'approved',
                                            question: "Как подготовиться к исследованию номер #{index}?",
                                            answer: "Подготовка к исследованию номер #{index}: #{'за восемь часов не принимать пищу, ' * 5}")
      end
      allow(Captain::AssistantResponse).to receive(:search).and_return(
        Captain::AssistantResponse.select('captain_assistant_responses.*, 0.1 AS neighbor_distance').where(id: responses.map(&:id))
      )
      allow(tool).to receive(:knowledge_graph_payload_for).and_return(knowledge_graph)

      before_size = JSON.pretty_generate(lookup_payload('подготовка к исследованию')).bytesize
      after_size = tool.perform(tool_context, query: 'подготовка к исследованию').bytesize
      RSpec.configuration.reporter.message("faq_lookup, 5 long answers with a knowledge graph: #{before_size} bytes -> #{after_size} bytes")

      expect(JSON.parse(tool.perform(tool_context, query: 'подготовка к исследованию'))['matches'].size).to eq(5)
      expect(after_size).to be < before_size * 0.7
    end
  end
end
