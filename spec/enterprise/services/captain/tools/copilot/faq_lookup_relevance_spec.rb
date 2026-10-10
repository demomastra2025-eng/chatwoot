require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::FaqLookupService, 'short query relevance with native retrieval' do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }
  let(:query_embedding) { [1.0] + Array.new(Captain::Llm::EmbeddingService::VECTOR_DIMENSIONS - 1, 0.0) }
  let(:questions) do
    {
      therapist: 'Как записаться на прием к терапевту?',
      therapist_visit: 'Как проходит прием терапевта?',
      pediatrician: 'Запись на прием к педиатру',
      podiatrist: 'Запись к подиатру',
      payment: 'Как оплатить прием картой?',
      hours: 'Часы работы клиники',
      cancellation: 'Как отменить запись на прием?',
      refund: 'How can I return my payment?',
      billing: 'How are clinic payments processed?',
      doctor: 'Дәрігер қабылдауы',
      account_policy: 'Account policy',
      accounting_policy: 'Accounting policy requirements'
    }
  end

  before do
    allow(Captain::Llm::UpdateEmbeddingJob).to receive(:perform_later)
    translation = instance_double(Captain::Llm::TranslateQueryService)
    allow(Captain::Llm::TranslateQueryService).to receive(:new).with(account: account).and_return(translation)
    allow(translation).to receive(:translate) { |query, **| query }
    embedding_service = instance_double(Captain::Llm::EmbeddingService)
    allow(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(embedding_service)
    allow(embedding_service).to receive(:get_embedding).and_return(query_embedding)
    allow(Captain::AssistantResponse).to receive(:search).and_call_original
  end

  def vector_with_similarity(score)
    [score, Math.sqrt(1 - (score**2))] + Array.new(Captain::Llm::EmbeddingService::VECTOR_DIMENSIONS - 2, 0.0)
  end

  def seed_corpus(scores)
    questions.to_h do |key, question|
      [key, create(:captain_assistant_response, account: account, assistant: assistant, question: question,
                                              answer: "Approved answer for #{key}", embedding: vector_with_similarity(scores.fetch(key, 0.1)))]
    end
  end

  {
    'хочу к терапевту' => [:therapist, { therapist: 0.42, pediatrician: 0.3 }],
    'можно прием терапевта' => [:therapist, { therapist: 0.52, therapist_visit: 0.3 }],
    'Хочу записаться к терапевту' => [:therapist, { therapist: 0.46 }],
    'хочу к терпаевту' => [:therapist, { therapist: 0.48 }],
    'прием педиатра' => [:pediatrician, { pediatrician: 0.49, therapist: 0.3 }],
    'оплатить картой' => [:payment, { payment: 0.5 }],
    'часы клиники' => [:hours, { hours: 0.46 }],
    'хочу отменить прием' => [:cancellation, { cancellation: 0.51, therapist: 0.3 }],
    'return my paymnt' => [:refund, { refund: 0.45 }],
    'return payments' => [:refund, { refund: 0.45, billing: 0.3 }],
    'clinic payment' => [:billing, { billing: 0.52, refund: 0.3 }],
    'дәрігерге' => [:doctor, { doctor: 0.46 }]
  }.each do |query, (expected, scores)|
    it "corroborates #{query.inspect} without weakening the strong semantic threshold" do
      corpus = seed_corpus(scores)
      payload = JSON.parse(service.execute(query: query))

      expect(payload).to include('result' => 'found', 'lookup_strategy' => 'corroborated_faq', 'total_count' => 1)
      expect(payload['matches'].first).to include(
        'id' => corpus.fetch(expected).id, 'score' => scores.fetch(expected),
        'relevance_threshold' => 0.7, 'relevance_threshold_passed' => false, 'question_corroboration_passed' => true
      )
      expect(payload.dig('retrieval_trace', 'relevance_check', 'corroboration')).to include('passed' => true, 'query_coverage' => 1.0)
      expect(Captain::AssistantResponse).to have_received(:search).with(query, account_id: account.id, assistant_id: assistant.id, limit: 5)
      # This lower-score decision is tied to the literal query evidence. It
      # must not be reused by the translated/semantic answer cache.
      expect(Captain::KnowledgeAnswerCacheEntry.count).to eq(0)
    end
  end

  {
    'оплата терапевта' => { therapist: 0.52, payment: 0.45 },
    'отменить запись терапевта' => { therapist: 0.52, cancellation: 0.46 },
    'стоимость приема терапевта' => { therapist: 0.52, payment: 0.43 },
    'как проехать в клинику' => { hours: 0.65 },
    'когда прием терапевта' => { therapist: 0.52, hours: 0.4 },
    'хочу к хирургу' => { therapist: 0.52, pediatrician: 0.42 },
    'хочу терапию' => { therapist: 0.52 },
    'хочу к подиатру' => { pediatrician: 0.52, podiatrist: 0.3 },
    'прием' => { therapist: 0.52, pediatrician: 0.48 },
    'проверка оплаты' => { payment: 0.52 },
    'погода завтра' => { therapist: 0.65, hours: 0.5 },
    'therapy' => { therapist: 0.6 },
    'не хочу к терапевту' => { therapist: 0.52 },
    'not clinic payments' => { billing: 0.52 },
    'clinical payments' => { billing: 0.52 },
    'дәрігерге ақы' => { doctor: 0.52 },
    'need accounting policy' => { account_policy: 0.52, accounting_policy: 0.3 }
  }.each do |query, scores|
    it "rejects the unrelated or different intent #{query.inspect} despite a moderately similar leader" do
      seed_corpus(scores)
      payload = JSON.parse(service.execute(query: query))

      expect(payload).to include('result' => 'not_found', 'total_count' => 0)
      expect(payload['matches']).to be_empty
      expect(payload.dig('retrieval_trace', 'relevance_check', 'corroboration', 'passed')).to be(false)
      expect(Captain::KnowledgeAnswerCacheEntry.count).to eq(0)
    end
  end

  it 'rejects an ambiguous pair and a candidate below the bounded semantic floor' do
    corpus = seed_corpus(therapist: 0.52, therapist_visit: 0.5)
    ambiguous = JSON.parse(service.execute(query: 'хочу к терапевту'))
    expect(ambiguous['matches']).to be_empty
    expect(ambiguous.dig('retrieval_trace', 'relevance_check', 'corroboration', 'reason')).to eq('ambiguous_question_matches')

    corpus.fetch(:therapist).update_columns(embedding: vector_with_similarity(0.39))
    corpus.fetch(:therapist_visit).update_columns(embedding: vector_with_similarity(0.2))
    below_floor = JSON.parse(service.execute(query: 'хочу к терапевту'))
    expect(below_floor['matches']).to be_empty
    expect(below_floor.dig('retrieval_trace', 'relevance_check', 'corroboration', 'reason')).to eq('below_semantic_floor')
  end

  it 'rejects closely scored native neighbors across singular and plural query forms' do
    seed_corpus(billing: 0.52, refund: 0.5)

    %w[payment payments].each do |query|
      payload = JSON.parse(service.execute(query: query))

      expect(payload['matches']).to be_empty
      expect(payload.dig('retrieval_trace', 'relevance_check', 'corroboration', 'reason')).to eq('ambiguous_question_matches')
    end
  end

  it 'does not let a lossy translation remove an unmatched intent in the original question' do
    seed_corpus(therapist: 0.52)
    translation = instance_double(Captain::Llm::TranslateQueryService, translate: 'хочу к терапевту')
    allow(Captain::Llm::TranslateQueryService).to receive(:new).with(account: account).and_return(translation)

    payload = JSON.parse(service.execute(query: 'оплата терапевта'))

    expect(payload['matches']).to be_empty
  end

  it 'keeps approved account/assistant visibility through native scoring rather than rescuing private neighbors' do
    corpus = seed_corpus(therapist: 0.42)
    other = create(:captain_assistant, account: account)
    create(:captain_assistant_response, account: account, assistant: other, visibility: :personal,
                                        question: questions[:therapist], answer: 'Private answer', embedding: vector_with_similarity(0.99))
    create(:captain_assistant_response, account: account, assistant: assistant, status: :pending,
                                        question: questions[:therapist], answer: 'Unapproved answer', embedding: vector_with_similarity(0.99))
    create(:captain_assistant_response, question: questions[:therapist], answer: 'Another account', embedding: vector_with_similarity(0.99))

    payload = JSON.parse(service.execute(query: 'хочу к терапевту'))

    expect(payload['matches'].pluck('id')).to eq([corpus.fetch(:therapist).id])
    expect(payload['matches'].pluck('answer')).to eq(['Approved answer for therapist'])
  end

  it 'preserves exact unembedded FAQ and strong semantic results' do
    corpus = seed_corpus(payment: 0.9)
    corpus.fetch(:therapist).update_columns(embedding: nil)
    exact = JSON.parse(service.execute(query: questions.fetch(:therapist)))
    expect(exact).to include('lookup_strategy' => 'lexical_exact', 'result' => 'found')
    expect(exact['matches'].first['id']).to eq(corpus.fetch(:therapist).id)

    strong = JSON.parse(service.execute(query: 'оплатить картой'))
    expect(strong).to include('lookup_strategy' => 'semantic_faq', 'result' => 'found')
    expect(strong['matches'].first).to include('id' => corpus.fetch(:payment).id, 'relevance_threshold_passed' => true)
  end
end
