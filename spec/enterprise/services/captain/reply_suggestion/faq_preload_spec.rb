# frozen_string_literal: true

require 'rails_helper'

# The FAQ answers close to the patient's message that a reply suggestion finds before the first model call: the vector search of
# faq_lookup with its threshold, at most three answers, only for an agent that has FAQ. All data is synthetic.
RSpec.describe Captain::ReplySuggestion::FaqPreload do
  let(:model) { 'google/gemini-embedding-001' }
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:embedder) { instance_double(Captain::Llm::EmbeddingService, embedding_model: model, get_embedding: unit_vector(0)) }

  before do
    allow(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(embedder)
  end

  def faq(question, answer, vector, owner: assistant)
    create(:captain_assistant_response, account: account, assistant: owner, question: question, answer: answer, status: 'approved')
      .tap { |response| response.update_columns(embedding: vector, embedding_model: model) } # rubocop:disable Rails/SkipsModelValidations
  end

  def preload(text = 'Как подготовиться к УЗИ?')
    described_class.start(account: account, text: text)
  end

  describe '.start' do
    it 'starts nothing for an account without an approved FAQ, or without text' do
      expect(preload).to be_nil

      faq('Вопрос', 'Ответ', unit_vector(0))

      expect(preload('   ')).to be_nil
      expect(preload).to be_a(described_class)
    end

    it 'embeds the words of the patient as a search query, cut to the start of a long message' do
      faq('Вопрос', 'Ответ', unit_vector(0))

      described_class.start(account: account, text: "#{'а' * 590} #{'б' * 100}").matches(assistant)

      expect(embedder).to have_received(:get_embedding).with(a_string_starting_with('а' * 590).and(have_attributes(length: 600)),
                                                             input_type: Captain::Llm::EmbeddingService::SEARCH_QUERY_INPUT_TYPE)
    end
  end

  it 'does not send a phone number or an IIN of the message to the embedding provider' do
    faq('Вопрос', 'Ответ', unit_vector(0))

    text = 'Мой ИИН 900101300123, телефон +7 701 000 00 01. Сколько стоит МРТ за 28.10.2026?'
    described_class.start(account: account, text: text).matches(assistant)

    expect(embedder).to have_received(:get_embedding).with('Мой ИИН , телефон . Сколько стоит МРТ за 28.10.2026?',
                                                           input_type: Captain::Llm::EmbeddingService::SEARCH_QUERY_INPUT_TYPE)
  end

  describe '#matches' do
    let!(:near) { faq('Как подготовиться к УЗИ?', 'Не есть за 6 часов.', unit_vector(0)) }

    it 'gives the question, the answer and the score of the answers above the threshold of faq_lookup' do
      expect(preload.matches(assistant)).to eq([{ question: 'Как подготовиться к УЗИ?', answer: 'Не есть за 6 часов.', score: 1.0 }])
    end

    it 'leaves out an answer below the threshold: similarity 0.7, the distance 0.3 of faq_lookup' do
      faq('Другой вопрос', 'Другой ответ', vector_at(0, 0.69))
      faq('Похожий вопрос', 'Похожий ответ', vector_at(0, 0.72))

      matches = preload.matches(assistant)

      expect(matches.pluck(:question)).to eq(['Как подготовиться к УЗИ?', 'Похожий вопрос'])
      expect(matches.last[:score]).to eq(0.72)
      expect(Captain::Tools::FaqLookupTool::SEMANTIC_SIMILARITY_THRESHOLD).to eq(0.7)
    end

    it 'gives three answers at most, the nearest first' do
      faq('Второй', 'Ответ 2', vector_at(0, 0.95))
      faq('Третий', 'Ответ 3', vector_at(0, 0.9))
      faq('Четвёртый', 'Ответ 4', vector_at(0, 0.85))

      expect(preload.matches(assistant).pluck(:question)).to eq(['Как подготовиться к УЗИ?', 'Второй', 'Третий'])
    end

    it 'keeps the total of the answers within the budget' do
      near.update!(answer: 'А' * 3500)
      faq('Второй', 'Б' * 600, vector_at(0, 0.95))

      matches = preload.matches(assistant)

      expect(matches.pluck(:question)).to eq(['Как подготовиться к УЗИ?'])
      expect(matches.first[:answer].length).to eq(3500)
    end

    it 'skips an oversized answer and keeps a shorter relevant one' do
      near.update!(answer: 'А' * (described_class::MAX_ANSWER_CHARS + 1))
      faq('Другой подходящий вопрос', 'Короткий ответ', vector_at(0, 0.95))

      expect(preload.matches(assistant).pluck(:answer)).to eq(['Короткий ответ'])
    end

    it 'reads only what the agent may see: the FAQ of another agent that is not shared is not read' do
      other = create(:captain_assistant, account: account)
      private_answer = faq('Личный вопрос', 'Личный ответ', unit_vector(0), owner: other)
      private_answer.update!(visibility: :personal)

      expect(preload.matches(assistant).pluck(:question)).to eq(['Как подготовиться к УЗИ?'])
    end

    it 'gives nothing to an agent without FAQ and does not search for it' do
      allow(assistant).to receive(:faq_entries?).and_return(false)
      allow(Captain::AssistantResponse).to receive(:nearest_to).and_call_original

      expect(preload.matches(assistant)).to eq([])
      expect(Captain::AssistantResponse).not_to have_received(:nearest_to)
    end

    it 'gives nothing when the message cannot be embedded, and says nothing to the agent about it' do
      allow(embedder).to receive(:get_embedding).and_raise(Captain::Llm::EmbeddingService::EmbeddingsError, 'down')

      expect(preload.matches(assistant)).to eq([])
    end

    it 'embeds once however many agents ask' do
      preload.tap { |started| 2.times { started.matches(assistant) } }

      expect(embedder).to have_received(:get_embedding).once
    end
  end

  it 'finds what Captain::AssistantResponse.search finds: one search, split into the embedding and the nearest answers' do
    faq('Вопрос', 'Ответ', unit_vector(0))
    faq('Далёкий', 'Ответ', unit_vector(5))

    via_search = Captain::AssistantResponse.search('Вопрос', account_id: account.id, assistant_id: assistant.id).map(&:id)
    via_preload = Captain::AssistantResponse.nearest_to(unit_vector(0), embedding_model: model, account_id: account.id,
                                                                        assistant_id: assistant.id).map(&:id)

    expect(via_preload).to eq(via_search)
  end
end
