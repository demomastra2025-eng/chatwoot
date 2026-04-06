require 'rails_helper'

RSpec.describe Captain::Llm::PdfProcessingService do
  let(:document) { create(:captain_document) }
  let(:service) { described_class.new(document) }

  describe '#process' do
    context 'when a PDF is attached' do
      before do
        document.pdf_file.attach(
          io: StringIO.new(File.binread(Rails.root.join('spec/assets/sample.pdf'))),
          filename: 'sample.pdf',
          content_type: 'application/pdf'
        )
      end

      it 'prepares the file locally without storing an OpenAI file id' do
        expect(service.process).to be true
      end
    end

    context 'when no PDF is attached' do
      it 'raises an upload error' do
        expect { service.process }.to raise_error(CustomExceptions::Pdf::UploadError)
      end
    end

    context 'when the prepared file is empty' do
      before do
        document.pdf_file.attach(
          io: StringIO.new(File.binread(Rails.root.join('spec/assets/sample.pdf'))),
          filename: 'sample.pdf',
          content_type: 'application/pdf'
        )
      end

      it 'raises an upload error' do
        allow(document.pdf_file.blob).to receive(:open).and_yield(StringIO.new)

        expect { service.process }.to raise_error(CustomExceptions::Pdf::UploadError)
      end
    end
  end
end
