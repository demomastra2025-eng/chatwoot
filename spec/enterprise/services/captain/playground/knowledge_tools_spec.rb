require 'rails_helper'

RSpec.describe Captain::Playground::KnowledgeTools do
  let(:fixtures) do
    {
      knowledge_documents: [
        { id: 1101, name: 'Clinic guide', external_link: 'https://example.test/guide', status: 'available', source_mode: 'url',
          created_at: '2026-10-01T10:00:00Z' },
        { id: 1102, name: 'Uploaded guide', filename: 'guide.pdf', sendable: true, status: 'available', source_mode: 'upload',
          content_type: 'application/pdf', file_size: 512, created_at: '2026-10-02T10:00:00Z' },
        { id: 1103, name: 'Hidden guide', visible: false, status: 'available', created_at: '2026-10-03T10:00:00Z' },
        { id: 1104, name: 'Processing guide', status: 'in_progress', created_at: '2026-10-04T10:00:00Z' }
      ],
      knowledge_chunks: [
        { id: 1201, document_id: 1101, chunk_index: 0, content: 'Preparation instructions for ultrasound', embedding_status: 'pending' },
        { id: 1202, document_id: 1103, chunk_index: 0, content: 'Secret ultrasound data', embedding_status: 'indexed' }
      ],
      faq_responses: [
        { id: 1301, question: 'When does the clinic open?', answer: 'At nine.', status: 'approved', document_id: 1101,
          created_at: '2026-10-01T10:00:00Z' },
        { id: 1302, question: 'How can I cancel?', answer: 'Contact the clinic.', status: 'approved', created_at: '2026-10-02T10:00:00Z' },
        { id: 1303, question: 'Hidden clinic question', answer: 'Private answer', status: 'approved', visible: false },
        { id: 1304, question: 'Pending clinic question', answer: 'Unapproved answer', status: 'pending' }
      ],
      articles: [
        { id: 1401, title: 'Published refund guide', content: 'Refund in fourteen days', status: 'published', category_id: 1501,
          portal_id: 1701, portal_name: 'Example portal', author_name: 'Example author', views: 5, meta: { title: 'Refund' },
          updated_at: '2026-10-01T10:00:00Z' },
        { id: 1402, title: 'Newer refund guide', content: 'Refund conditions', status: 'published', category_id: 1502,
          updated_at: '2026-10-02T10:00:00Z' },
        { id: 1403, title: 'Draft refund guide', content: 'Draft refund conditions', status: 'draft', category_id: 1501,
          updated_at: '2026-10-03T10:00:00Z' }
      ],
      categories: [{ id: 1501, name: 'Billing' }, { id: 1502, name: 'Support' }],
      canned_responses: [
        { id: 1601, short_code: 'refund_a', content: 'Refund process', created_at: '2026-10-01T10:00:00Z' },
        { id: 1602, short_code: 'refund_b', content: 'Refund conditions' },
        { id: 1603, short_code: 'shipping', content: 'Shipping conditions' }
      ]
    }.deep_stringify_keys
  end

  let(:harness_class) do
    Class.new do
      include Captain::Playground::KnowledgeTools

      def initialize(data)
        @data = data
        @session = Struct.new(:id).new('fixture-session')
      end

      def call(handler, **arguments)
        @args = arguments.deep_stringify_keys
        send(handler)
      end
    end
  end
  let(:harness) { harness_class.new(fixtures) }

  it 'returns exact approved FAQ payloads and lexical documentation without semantic calls or snapshot mutations' do
    original = fixtures.deep_dup
    expect(Captain::Llm::EmbeddingService).not_to receive(:new)
    expect(Captain::Llm::TranslateQueryService).not_to receive(:new)
    expect(Captain::Knowledge::AnswerCache).not_to receive(:new)
    faq = harness.call(:faq_lookup, query: '  When does the clinic open? ')
    expect(faq).to include(total_count: 1, result: 'found', lookup_strategy: 'lexical_exact', simulated: true)
    expect(faq[:matches].first).to include(id: 1301, question: 'When does the clinic open?', answer: 'At nine.', score: 1.0)
    expect(faq[:retrieval_trace]).to include(semantic_attempted: false, response_ids: [1301], document_ids: [1101])

    documentation = harness.call(:search_documentation, query: 'CLINIC')
    expect(documentation[:matches].pluck(:id)).to eq([1302, 1301])
    expect(documentation[:retrieval_trace]).to include(strategy: 'lexical', degraded: false, semantic_attempted: false)
    expect(fixtures).to eq(original)
  end

  it 'falls back to visible document chunks and reports a meaningful empty result' do
    result = harness.call(:faq_lookup, query: 'ultrasound')
    expect(result[:matches]).to contain_exactly(include(type: 'document_chunk', id: 1201, document_id: 1101,
                                                      answer: 'Preparation instructions for ultrasound', source: 'https://example.test/guide'))
    expect(result[:retrieval_trace]).to include(response_ids: [], document_ids: [1101], document_chunk_ids: [1201])
    expect(harness.call(:faq_lookup, query: 'nonexistent')).to include(result: 'not_found', total_count: 0, matches: [])
    expect { harness.call(:search_documentation, query: ' ') }.to raise_error(ArgumentError, 'query is required')
  end

  it 'caps FAQ matches at the production result limit' do
    fixtures['faq_responses'] = 7.times.map do |index|
      { 'id' => 1310 + index, 'question' => 'Clinic hours', 'answer' => 'Open at nine', 'status' => 'approved' }
    end
    expect(harness.call(:faq_lookup, query: 'Clinic hours')[:matches].size).to eq(Captain::Tools::FaqLookupTool::SEMANTIC_RESULT_LIMIT)
  end

  it 'lists only visible available source documents with bounded results and unusable synthetic file artifacts' do
    result = harness.call(:captain_documents, query: 'guide', sendable_only: true)
    expect(result[:documents]).to contain_exactly(include(document_id: 1102, sendable: true, filename: 'guide.pdf',
                                                        artifact_id: 'trial_fixture-session_document_1102'))
    expect(result[:documents].first).not_to have_key(:external_link)
    expect { Captain::Tools::DocumentArtifactToken.decode(result[:documents].first[:artifact_id]) }
      .to raise_error(Captain::Tools::DocumentArtifactToken::InvalidToken)
    expect(harness.call(:captain_documents, query: 'EXAMPLE.TEST')[:documents].pluck(:document_id)).to eq([1101])
    expect(harness.call(:captain_documents, limit: 1)[:documents].pluck(:document_id)).to eq([1102])
    fixtures['knowledge_documents'] = 25.times.map { |index| { 'id' => 1110 + index, 'name' => 'Guide', 'status' => 'available' } }
    expect(harness.call(:captain_documents)[:documents].size).to eq(10)
    expect(harness.call(:captain_documents, limit: 100)[:documents].size).to eq(20)
  end

  it 'uses article status/category/query filters, total count before limit, and production full-card fields' do
    result = harness.call(:search_articles, query: 'REFUND', limit: 1)
    expect(result).to include(filters: { query: 'REFUND', status: 'published' }, total_count: 2)
    expect(result[:articles].pluck(:id)).to eq([1402])
    filtered = harness.call(:search_articles, category_id: 1501)
    expect(filtered[:articles].pluck(:id)).to eq([1401])
    expect(harness.call(:search_articles, status: 'draft')[:articles].pluck(:id)).to eq([1403])
    expect { harness.call(:search_articles, category_id: 999) }.to raise_error(ArgumentError, /Unknown category_id/)
    article = harness.call(:article_details, article_id: 1401)[:article]
    expect(article).to include(content: 'Refund in fourteen days', views: 5, meta: { 'title' => 'Refund' },
                              portal_name: 'Example portal', author_name: 'Example author', updated_at: '2026-10-01T10:00:00Z')
    expect(Captain::ToolResult.error?(harness.call(:article_details, article_id: 999))).to be(true)
  end

  it 'searches canned responses by content or short code and counts all matches before applying the production limit' do
    result = harness.call(:search_canned_responses, query: 'REFUND', limit: 1)
    expect(result).to include(filters: { query: 'REFUND' }, total_count: 2)
    expect(result[:canned_responses]).to contain_exactly(include(id: 1601, short_code: 'refund_a', content: 'Refund process'))
    expect(harness.call(:search_canned_responses, query: 'conditions')[:canned_responses].pluck(:id)).to eq([1602, 1603])
    expect(harness.call(:search_canned_responses, query: 'nonexistent')).to include(total_count: 0, canned_responses: [])
  end

  context 'through the production schemas and tool wrapper with real-data read disabled' do
    let(:account) { create(:account) }
    let(:user) { create(:user, :administrator, account: account) }
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:session) { Captain::Playground::Session.new(account: account, user: user, assistant: assistant) }

    before do
      allow(Captain::ToolSafety).to receive(:check_arguments!)
      allow(Captain::ToolSafety).to receive(:check_result!)
      allow(assistant).to receive(:allowed_agent_tool_ids).and_return(%w[
        search_documentation list_captain_documents faq_lookup get_article search_articles search_canned_responses
      ])
    end
    after { Current.reset }

    def wrapped(workspace, id)
      definition = Captain::ToolRegistry.definition_for(id)
      tool = if definition.agent_tool_class == Captain::Tools::Agent::AccountToolAdapter
               definition.agent_tool_class.new(assistant, tool_id: id)
             else
               definition.agent_tool_class.new(assistant)
             end
      state = workspace.state.merge(source: 'playground', account_id: account.id, assistant_id: assistant.id)
      context = Captain::Runtime::RunContext.new({ state: state, playground_session: workspace })
      Captain::Runtime::ToolWrapper.new(tool, context)
    end

    it 'returns fixture knowledge and session-bound IDs with no live lookups, embeddings, caching, or business writes' do
      assistant
      business_models = [Contact, Conversation, Message, Captain::Document, Captain::AssistantResponse, Article, CannedResponse,
                         Scheduling::Appointment, Integrations::Medelement::ProviderCommand]
      counts = business_models.map(&:count)
      expect(Captain::Llm::EmbeddingService).not_to receive(:new)
      expect(Captain::Llm::TranslateQueryService).not_to receive(:new)
      expect(Captain::Knowledge::AnswerCache).not_to receive(:new)
      expect(Captain::AssistantResponse).not_to receive(:exact_search)
      expect(Captain::AssistantResponse).not_to receive(:lexical_search)
      expect(Captain::DocumentChunk).not_to receive(:where)
      expect(account).not_to receive(:captain_documents)
      expect(account).not_to receive(:articles)
      expect(account).not_to receive(:canned_responses)

      session.with_lock do |workspace|
        workspace.scenario.data.merge!(fixtures.deep_dup)
        expect(workspace.read_enabled?).to be(false)
        faq = JSON.parse(wrapped(workspace, 'faq_lookup').call(query: 'When does the clinic open?'))
        expect(faq).to include('simulated' => true, 'result' => 'found')
        expect(faq['matches'].first['id']).to be_negative
        expect(JSON.parse(wrapped(workspace, 'search_documentation').call(query: 'ultrasound'))['matches'].first['answer'])
          .to eq('Preparation instructions for ultrasound')
        documents = JSON.parse(wrapped(workspace, 'list_captain_documents').call(sendable_only: true))['documents']
        expect(documents.first['document_id']).to be_negative
        expect(documents.first['artifact_id']).to start_with("trial_#{workspace.id}_document_")
        articles = JSON.parse(wrapped(workspace, 'search_articles').call(query: 'refund', limit: 1))
        expect(articles).to include('total_count' => 2)
        article_id = articles['articles'].first['id']
        expect(article_id).to be_negative
        expect(JSON.parse(wrapped(workspace, 'get_article').call(article_id: article_id)).dig('article', 'title')).to eq('Newer refund guide')
        workspace.set_permissions!(read: true, write: false)
        expect(JSON.parse(wrapped(workspace, 'get_article').call(article_id: article_id)).dig('article', 'title')).to eq('Newer refund guide')
        foreign_id = Captain::Playground::SyntheticNamespace.new(SecureRandom.uuid).encode({ article_id: 1402 })[:article_id]
        expect(wrapped(workspace, 'get_article').call(article_id: foreign_id)).to include('another Playground session')
        workspace.set_permissions!(read: false, write: false)
        canned = JSON.parse(wrapped(workspace, 'search_canned_responses').call(query: 'refund', limit: 1))
        expect(canned).to include('total_count' => 2)
        expect(canned['canned_responses'].first['id']).to be_negative
      end
      expect(business_models.map(&:count)).to eq(counts)
    end
  end
end
