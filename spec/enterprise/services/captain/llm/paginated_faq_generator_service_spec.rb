require 'rails_helper'

RSpec.describe Captain::Llm::PaginatedFaqGeneratorService do
  let(:document) do
    create(:captain_document).tap do |record|
      record.pdf_file.attach(
        io: StringIO.new(File.binread(Rails.root.join('spec/assets/sample.pdf'))),
        filename: 'sample.pdf',
        content_type: 'application/pdf'
      )
    end
  end
  let(:service) { described_class.new(document, pages_per_chunk: 5) }
  let(:chat) { instance_double(RubyLLM::Chat) }
  let(:response) { instance_double(RubyLLM::Message, content: response_content) }
  let(:empty_response) { instance_double(RubyLLM::Message, content: empty_response_content) }
  let(:response_content) do
    {
      'faqs' => [
        { 'question' => 'What is this document about?', 'answer' => 'It explains key concepts.' }
      ],
      'has_content' => true
    }
  end
  let(:empty_response_content) do
    {
      'faqs' => [],
      'has_content' => false
    }
  end

  describe '#generate' do
    context 'when document has no PDF source' do
      let(:document) { create(:captain_document, external_link: 'https://example.com/article') }

      it 'raises an error' do
        expect { service.generate }.to raise_error(CustomExceptions::Pdf::FaqGenerationError)
      end
    end

    context 'when generating FAQs from PDF pages' do
      before do
        allow(service).to receive(:chat).with(model: service.model).and_return(chat)
        allow(chat).to receive(:model).and_return(service.model)
        allow(chat).to receive(:with_schema).with(Captain::Llm::Schemas::PaginatedFaqChunk).and_return(chat)
      end

      it 'generates FAQs from paginated content using the PDF attachment directly' do
        responses = [response, empty_response]

        expect(service).to receive(:ask_chat).twice do |llm_chat, content|
          expect(llm_chat).to eq(chat)
          expect_pdf_attachment_content(content)
          responses.shift
        end

        faqs = service.generate

        expect(faqs).to have_attributes(size: 1)
        expect(faqs.first['question']).to eq('What is this document about?')
      end

      it 'stops when no more content' do
        allow(service).to receive(:ask_chat).and_return(empty_response)

        faqs = service.generate

        expect(faqs).to be_empty
      end

      it 'respects max iterations limit' do
        allow(service).to receive(:ask_chat).and_return(response)
        service.instance_variable_set(:@iterations_completed, 19)

        service.generate

        expect(service.iterations_completed).to eq(20)
      end

      it 'skips malformed FAQs without questions during deduplication' do
        responses = [
          instance_double(
            RubyLLM::Message,
            content: {
              'faqs' => [
                { 'question' => 'What is this document about?', 'answer' => 'It explains key concepts.' },
                { 'answer' => 'Missing question should be ignored.' },
                { 'question' => nil, 'answer' => 'Nil question should be ignored.' }
              ],
              'has_content' => true
            }
          ),
          empty_response
        ]

        allow(service).to receive(:ask_chat) { responses.shift }

        faqs = service.generate

        expect(faqs.pluck('question')).to eq(['What is this document about?'])
      end
    end
  end

  describe '#should_continue_processing?' do
    it 'stops at max iterations' do
      service.instance_variable_set(:@iterations_completed, 20)

      expect(service.should_continue_processing?(faqs: ['faq'], has_content: true)).to be false
    end

    it 'stops when no FAQs returned' do
      expect(service.should_continue_processing?(faqs: [], has_content: true)).to be false
    end

    it 'continues when FAQs exist and under limits' do
      expect(service.should_continue_processing?(faqs: ['faq'], has_content: true)).to be true
    end
  end

  describe '#model' do
    it 'resolves PDF FAQ generation through the account assistant model instead of the OpenAI PDF fallback' do
      expect(Llm::Config).to receive(:model_for).with(
        feature: :assistant,
        account: document.account,
        fallback: Llm::Config::DEFAULT_MODEL
      ).and_return('openai/gpt-5.4')

      expect(service.model).to eq('openai/gpt-5.4')
    end
  end

  def expect_pdf_attachment_content(content)
    expect(content).to be_a(RubyLLM::Content)
    expect(content.text).to be_present
    expect(content.attachments.size).to eq(1)
    expect(content.attachments.first.source).to eq(document.pdf_file)
  end
end
