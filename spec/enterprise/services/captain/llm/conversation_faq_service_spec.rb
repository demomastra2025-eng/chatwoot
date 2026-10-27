require 'rails_helper'

RSpec.describe Captain::Llm::ConversationFaqService do
  let(:captain_assistant) { create(:captain_assistant) }
  let(:conversation) { create(:conversation, first_reply_created_at: Time.zone.now) }
  let(:service) { described_class.new(captain_assistant, conversation) }
  let(:embedding_service) { instance_double(Captain::Llm::EmbeddingService, embedding_model: 'google/gemini-embedding-001') }
  let(:mock_chat) { instance_double(RubyLLM::Chat) }
  let(:sample_faqs) do
    [
      { 'question' => 'What is the purpose?', 'answer' => 'To help users.' },
      { 'question' => 'How does it work?', 'answer' => 'Through AI.' }
    ]
  end
  let(:mock_response) do
    instance_double(RubyLLM::Message, content: { faqs: sample_faqs })
  end

  before do
    upsert_installation_config('CAPTAIN_OPEN_AI_API_KEY', 'test-key')
    allow(Captain::Llm::EmbeddingService).to receive(:new).and_return(embedding_service)
    allow(RubyLLM).to receive(:chat).and_return(mock_chat)
    allow(mock_chat).to receive(:with_temperature).and_return(mock_chat)
    allow(mock_chat).to receive(:with_params).and_return(mock_chat)
    allow(mock_chat).to receive(:with_headers).and_return(mock_chat)
    allow(mock_chat).to receive(:with_instructions).and_return(mock_chat)
    allow(mock_chat).to receive(:with_schema).and_return(mock_chat)
    allow(mock_chat).to receive(:model).and_return(instance_double('RubyLLM::Model::Info', id: 'gpt-5.4-mini'))
    allow(mock_chat).to receive(:ask).and_return(mock_response)
  end

  describe '#generate_and_deduplicate' do
    context 'when successful' do
      before do
        allow(embedding_service).to receive(:get_embedding).and_return([0.1, 0.2, 0.3])
        allow(service).to receive(:find_similar_faqs).and_return([])
      end

      it 'creates new FAQs for valid conversation content' do
        expect do
          service.generate_and_deduplicate
        end.to change(captain_assistant.responses, :count).by(2)
      end

      it 'saves FAQs with pending status linked to conversation' do
        service.generate_and_deduplicate
        expect(
          captain_assistant.responses.pluck(:question, :answer, :status, :documentable_id)
        ).to contain_exactly(
          ['What is the purpose?', 'To help users.', 'pending', conversation.id],
          ['How does it work?', 'Through AI.', 'pending', conversation.id]
        )
      end
    end

    context 'without human interaction' do
      let(:conversation) { create(:conversation) }

      it 'returns an empty array without generating FAQs' do
        expect(service.generate_and_deduplicate).to eq([])
      end

      it 'does not call the LLM API' do
        expect(RubyLLM).not_to receive(:chat)
        service.generate_and_deduplicate
      end

      context 'when the conversation has a finalized voice transcript only in call-session metadata' do
        before do
          allow(embedding_service).to receive(:get_embedding).and_return([0.1, 0.2, 0.3])
          allow(service).to receive(:find_similar_faqs).and_return([])
          create(
            :telephony_call_session,
            account: conversation.account,
            conversation: conversation,
            inbox: conversation.inbox,
            external_call_ref: 'voice-faq-metadata-call-1',
            metadata: {
              'ai_voice' => {
                'transcript' => {
                  'final_items' => [
                    { 'speaker' => 'caller', 'text' => 'Можно ли оплатить картой?' },
                    { 'speaker' => 'ai', 'text' => 'Да, оплатить картой можно.' }
                  ]
                }
              }
            }
          )
        end

        it 'treats the metadata transcript as human interaction and generates FAQs' do
          expect do
            service.generate_and_deduplicate
          end.to change(captain_assistant.responses, :count).by(2)
        end
      end
    end

    context 'with explicit current-call content' do
      let(:conversation) { create(:conversation) }
      let(:current_call_content) { "Caller: Можно оплатить картой?\nAssistant: Да, можно." }
      let(:service) { described_class.new(captain_assistant, conversation, content: current_call_content) }

      before do
        allow(embedding_service).to receive(:get_embedding).and_return([0.1, 0.2, 0.3])
        allow(service).to receive(:find_similar_faqs).and_return([])
      end

      it 'uses only the supplied call transcript and treats the caller label as human interaction' do
        expect(mock_chat).to receive(:ask).with(current_call_content).and_return(mock_response)

        service.generate_and_deduplicate
      end
    end

    context 'when finding lexical duplicates' do
      let(:conversation) { create(:conversation, account: captain_assistant.account, first_reply_created_at: Time.zone.now) }
      let(:sample_faqs) do
        [{ 'question' => 'Как звучит слоган компании?', 'answer' => 'Акуна Матата!' }]
      end

      before do
        create(
          :captain_assistant_response,
          account: captain_assistant.account,
          assistant: nil,
          visibility: :general,
          question: 'Назовите слоган компании',
          answer: 'акуна матата',
          status: 'approved'
        )
      end

      it 'does not invoke embeddings or create pending FAQ for the same normalized answer' do
        expect(embedding_service).not_to receive(:get_embedding)

        expect do
          service.generate_and_deduplicate
        end.not_to change(captain_assistant.responses, :count)
      end
    end

    context 'when finding duplicates' do
      let(:existing_response) do
        create(:captain_assistant_response, assistant: captain_assistant, question: 'Similar question', answer: 'Similar answer')
      end
      let(:similar_neighbor) do
        OpenStruct.new(
          id: 1,
          question: existing_response.question,
          answer: existing_response.answer,
          neighbor_distance: 0.1
        )
      end

      before do
        allow(embedding_service).to receive(:get_embedding).and_return([0.1, 0.2, 0.3])
        allow(service).to receive(:find_similar_faqs).and_return([similar_neighbor])
      end

      it 'filters out duplicate FAQs based on embedding similarity' do
        expect do
          service.generate_and_deduplicate
        end.not_to change(captain_assistant.responses, :count)
      end
    end

    context 'when LLM API fails' do
      before do
        allow(mock_chat).to receive(:ask).and_raise(RubyLLM::Error.new(nil, 'API Error'))
        allow(Rails.logger).to receive(:error)
      end

      it 'returns empty array and logs the error' do
        expect(Rails.logger).to receive(:error).with('LLM API Error: API Error')
        expect(service.generate_and_deduplicate).to eq([])
      end

      context 'when configured to expose the error to its caller' do
        let(:service) { described_class.new(captain_assistant, conversation, raise_on_error: true) }

        it 'raises the provider error for retry-aware orchestration' do
          expect { service.generate_and_deduplicate }.to raise_error(RubyLLM::Error, 'API Error')
        end
      end
    end

    context 'when JSON parsing fails' do
      let(:invalid_response) do
        instance_double(RubyLLM::Message, content: 'invalid json')
      end

      before do
        allow(mock_chat).to receive(:ask).and_return(invalid_response)
        allow(Rails.logger).to receive(:error)
      end

      it 'handles structured-output parsing errors gracefully' do
        expect(Rails.logger).to receive(:error).with(/LLM API Error: Structured output response was not valid JSON/)
        expect(service.generate_and_deduplicate).to eq([])
      end
    end

    context 'when response content is nil' do
      let(:nil_response) do
        instance_double(RubyLLM::Message, content: nil)
      end

      before do
        allow(mock_chat).to receive(:ask).and_return(nil_response)
      end

      it 'returns empty array' do
        expect(service.generate_and_deduplicate).to eq([])
      end
    end
  end

  describe 'language handling' do
    context 'when conversation has different language' do
      let(:account) { create(:account, locale: 'fr') }
      let(:conversation) do
        create(:conversation, account: account, first_reply_created_at: Time.zone.now)
      end

      before do
        allow(embedding_service).to receive(:get_embedding).and_return([0.1, 0.2, 0.3])
        allow(service).to receive(:find_similar_faqs).and_return([])
      end

      it 'uses account language for system prompt' do
        expect(Captain::Llm::SystemPromptsService).to receive(:conversation_faq_generator)
          .with('french')
          .at_least(:once)
          .and_call_original

        service.generate_and_deduplicate
      end
    end
  end

  describe 'the embedding duplicate check' do
    let(:model) { 'google/gemini-embedding-001' }
    let(:account) { captain_assistant.account }
    let(:conversation) { create(:conversation, account: account, first_reply_created_at: Time.zone.now) }

    def faq(question, vector, model_name: model)
      create(:captain_assistant_response, account: account, assistant: captain_assistant, question: question, answer: 'Ответ', status: :approved)
        .tap { |record| record.update_columns(embedding: vector, embedding_model: model_name) } # rubocop:disable Rails/SkipsModelValidations
    end

    it 'calls two FAQs the same only at cosine similarity 0.95 or more: FAQs written from one template are 0.88-0.92 close' do
      template_twin = faq('Где принимает врач А?', vector_at(0, 0.92))
      paraphrase = faq('Где ведёт приём врач Б?', vector_at(0, 0.96))

      duplicates = service.send(:find_similar_faqs, unit_vector(0), model)

      expect(duplicates.map(&:id)).to eq([paraphrase.id])
      expect(duplicates.map(&:id)).not_to include(template_twin.id)
      expect(described_class::DISTANCE_THRESHOLD).to eq(0.05)
    end

    it 'compares the new FAQ only with the FAQs whose vector the same model made' do
      same_model = faq('Один вопрос', vector_at(0, 0.99))
      faq('Другой вопрос', vector_at(0, 0.99), model_name: 'text-embedding-3-large')
      faq('Без отметки', vector_at(0, 0.99), model_name: nil)

      expect(service.send(:find_similar_faqs, unit_vector(0), model).map(&:id)).to eq([same_model.id])
    end

    it 'embeds the new FAQ with the model in force and compares it with the vectors of that model' do
      existing = faq('Один вопрос', vector_at(0, 0.99))
      allow(embedding_service).to receive(:get_embedding).and_return(unit_vector(0))

      faq_hash = { 'question' => 'Совсем другое', 'answer' => 'Другое' }
      duplicates = service.send(:find_embedding_duplicates, faq_hash)

      expect(duplicates.map(&:id)).to eq([existing.id])
      expect(embedding_service).to have_received(:get_embedding)
        .with('Совсем другое: Другое', input_type: Captain::Llm::EmbeddingService::SEARCH_QUERY_INPUT_TYPE)
    end
  end
end
