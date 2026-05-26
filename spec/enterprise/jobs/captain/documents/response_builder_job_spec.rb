require 'rails_helper'

RSpec.describe Captain::Documents::ResponseBuilderJob, type: :job do
  let(:assistant) { create(:captain_assistant) }
  let(:document) { create(:captain_document, assistant: assistant) }
  let(:faq_generator) { instance_double(Captain::Llm::FaqGeneratorService) }
  let(:faqs) do
    [
      { 'question' => 'What is Ruby?', 'answer' => 'A programming language' },
      { 'question' => 'What is Rails?', 'answer' => 'A web framework' }
    ]
  end

  before do
    allow(Captain::Llm::FaqGeneratorService).to receive(:new)
      .with(document.faq_generation_text, document.account.locale_english_name, account_id: document.account_id)
      .and_return(faq_generator)
    allow(faq_generator).to receive(:generate).and_return(faqs)
  end

  describe '#perform' do
    context 'when processing a document' do
      it 'deletes previous responses' do
        existing_response = create(:captain_assistant_response, documentable: document)

        described_class.new.perform(document)

        expect { existing_response.reload }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it 'skips generation without deleting existing responses when FAQ generation is disabled' do
        document.update!(faq_generation_enabled: false)
        existing_response = create(:captain_assistant_response, documentable: document)

        described_class.new.perform(document)

        expect(existing_response.reload).to be_present
        expect(Captain::Llm::FaqGeneratorService).not_to have_received(:new)
      end

      it 'creates new responses for each FAQ' do
        expect do
          described_class.new.perform(document)
        end.to change(Captain::AssistantResponse, :count).by(2)

        responses = document.responses.reload
        expect(responses.count).to eq(2)

        first_response = responses.first
        expect(first_response.question).to eq('What is Ruby?')
        expect(first_response.answer).to eq('A programming language')
        expect(first_response.assistant).to eq(assistant)
        expect(first_response.documentable).to eq(document)
      end

      it 'persists source text chunks and links generated responses to their source chunk' do
        stub_const('Captain::Documents::ResponseBuilderJob::TEXT_CHUNK_SIZE', 12)
        document.update!(source_text: 'Alpha chunk. Beta chunk.', content: 'preview')

        allow(Captain::Llm::FaqGeneratorService).to receive(:new) do |chunk, language, account_id:|
          expect(language).to eq(document.account.locale_english_name)
          expect(account_id).to eq(document.account_id)
          instance_double(
            Captain::Llm::FaqGeneratorService,
            generate: [{ 'question' => "Question for #{chunk.strip}?", 'answer' => "Answer from #{chunk.strip}" }]
          )
        end

        described_class.new.perform(document)

        chunks = document.document_chunks.order(:chunk_index)
        expect(chunks.pluck(:chunk_index)).to eq([0, 1])
        expect(chunks.first.content).to eq('Alpha chunk.')
        expect(chunks.second.content).to eq(' Beta chunk.')
        expect(chunks.pluck(:content_sha256)).to all(be_present)
        expect(document.responses.reload.pluck(:document_chunk_id)).to match_array(chunks.pluck(:id))
      end

      it 'replaces stale source text chunks on regeneration' do
        stale_chunk = document.document_chunks.create!(
          account: document.account,
          assistant: document.assistant,
          chunk_index: 0,
          content: 'stale',
          content_sha256: 'stale'
        )

        described_class.new.perform(document)

        expect { stale_chunk.reload }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it 'keeps first chunk provenance when duplicate generated questions are deduplicated' do
        stub_const('Captain::Documents::ResponseBuilderJob::TEXT_CHUNK_SIZE', 12)
        document.update!(source_text: 'Alpha chunk. Beta chunk.', content: 'preview')

        allow(Captain::Llm::FaqGeneratorService).to receive(:new) do |chunk, _language, account_id:|
          expect(account_id).to eq(document.account_id)
          instance_double(
            Captain::Llm::FaqGeneratorService,
            generate: [{ 'question' => 'Repeated question?', 'answer' => "Answer from #{chunk.strip}" }]
          )
        end

        described_class.new.perform(document)

        response = document.responses.reload.sole
        expect(response.answer).to eq('Answer from Alpha chunk.')
        expect(response.document_chunk).to eq(document.document_chunks.order(:chunk_index).first)
      end

      it 'does not replace responses with stale generated results when source text changes before commit' do
        document.responses.create!(
          question: 'Existing?',
          answer: 'Existing answer',
          assistant: assistant,
          documentable: document
        )

        allow(document).to receive(:with_lock) do |&block|
          document.update!(source_text: 'Changed source text')
          block.call
        end

        described_class.new.perform(document)

        expect(document.responses.reload.sole.answer).to eq('Existing answer')
        expect(document.document_chunks).to be_empty
      end
    end

    context 'with different locales' do
      let(:spanish_account) { create(:account, locale: 'pt') }
      let(:spanish_assistant) { create(:captain_assistant, account: spanish_account) }
      let(:spanish_document) { create(:captain_document, assistant: spanish_assistant, account: spanish_account) }
      let(:spanish_faq_generator) { instance_double(Captain::Llm::FaqGeneratorService) }

      before do
        allow(Captain::Llm::FaqGeneratorService).to receive(:new)
          .with(spanish_document.content, 'portuguese', account_id: spanish_document.account_id)
          .and_return(spanish_faq_generator)
        allow(spanish_faq_generator).to receive(:generate).and_return(faqs)
      end

      it 'passes the correct locale to FAQ generator' do
        described_class.new.perform(spanish_document)

        expect(Captain::Llm::FaqGeneratorService).to have_received(:new)
          .with(spanish_document.content, 'portuguese', account_id: spanish_document.account_id)
      end
    end

    context 'when processing a PDF document' do
      let(:pdf_document) do
        doc = create(:captain_document, assistant: assistant)
        allow(doc).to receive(:pdf_document?).and_return(true)
        allow(doc).to receive(:update!).and_return(true)
        allow(doc).to receive(:metadata).and_return({})
        doc
      end
      let(:paginated_service) { instance_double(Captain::Llm::PaginatedFaqGeneratorService) }
      let(:pdf_faqs) do
        [{ 'question' => 'What is in the PDF?', 'answer' => 'Important content' }]
      end

      before do
        allow(Captain::Llm::PaginatedFaqGeneratorService).to receive(:new)
          .with(pdf_document, anything)
          .and_return(paginated_service)
        allow(paginated_service).to receive(:generate).and_return(pdf_faqs)
        allow(paginated_service).to receive(:total_pages_processed).and_return(10)
        allow(paginated_service).to receive(:iterations_completed).and_return(1)
      end

      it 'uses paginated FAQ generator for PDFs without extracted source text' do
        expect(Captain::Llm::PaginatedFaqGeneratorService).to receive(:new).with(pdf_document, anything)

        described_class.new.perform(pdf_document)
      end

      it 'uses extracted PDF source text when present' do
        allow(pdf_document).to receive(:source_text).and_return('Extracted PDF text')
        allow(Captain::Llm::FaqGeneratorService).to receive(:new)
          .with('Extracted PDF text', pdf_document.account.locale_english_name, account_id: pdf_document.account_id)
          .and_return(faq_generator)

        described_class.new.perform(pdf_document)

        expect(Captain::Llm::PaginatedFaqGeneratorService).not_to have_received(:new)
        expect(Captain::Llm::FaqGeneratorService).to have_received(:new)
          .with('Extracted PDF text', pdf_document.account.locale_english_name, account_id: pdf_document.account_id)
      end

      it 'stores pagination metadata' do
        expect(pdf_document).to receive(:update!).with(hash_including(metadata: hash_including('faq_generation')))

        described_class.new.perform(pdf_document)
      end

      it 'leaves paginated responses without source chunk linkage until page chunks are persisted' do
        described_class.new.perform(pdf_document)

        expect(pdf_document.responses.reload.sole.document_chunk_id).to be_nil
      end
    end
  end
end
