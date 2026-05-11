require 'rails_helper'

RSpec.describe Captain::Documents::SourceTextExtractor do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:document) do
    build(:captain_document, assistant: assistant, account: account, external_link: nil).tap do |record|
      record.pdf_file.attach(
        io: StringIO.new('%PDF-1.4 file'),
        filename: 'manual.pdf',
        content_type: 'application/pdf'
      )
      record.save!
    end
  end

  describe '.preview' do
    it 'keeps bounded content preview separate from full source text' do
      source_text = 'a' * 200_010

      expect(described_class.preview(source_text).length).to eq(200_000)
    end
  end

  describe '#extract_pdf_text' do
    it 'extracts and normalizes PDF text with pdftotext' do
      status = instance_double(Process::Status, success?: true, exitstatus: 0)
      allow(Open3).to receive(:capture3).and_return(["Line one\r\nLine two\n", '', status])

      expect(described_class.new(document).extract_pdf_text).to eq("Line one\nLine two")
      expect(Open3).to have_received(:capture3).with('pdftotext', '-layout', kind_of(String), '-')
    end

    it 'returns nil when pdftotext is unavailable' do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

      expect(described_class.new(document).extract_pdf_text).to be_nil
    end
  end
end
