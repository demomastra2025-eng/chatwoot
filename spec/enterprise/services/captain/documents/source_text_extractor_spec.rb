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
      allow(described_class).to receive(:capture_command_with_limits).and_return(["Line one\r\nLine two\n", '', status, false])

      expect(described_class.new(document).extract_pdf_text).to eq("Line one\nLine two")
      expect(described_class).to have_received(:capture_command_with_limits).with('pdftotext', '-layout', kind_of(String), '-')
    end

    it 'returns nil when pdftotext is unavailable' do
      allow(described_class).to receive(:capture_command_with_limits).and_raise(Errno::ENOENT)

      expect(described_class.new(document).extract_pdf_text).to be_nil
    end
  end

  describe '.extract_text_from_tempfile' do
    it 'extracts OpenXML documents through the no-key office fallback' do
      tempfile = Tempfile.new(['manual', '.docx'])
      status = instance_double(Process::Status, success?: true, exitstatus: 0)
      allow(described_class).to receive(:capture_command_with_limits).and_return(["Workspace manual\n", '', status, false])

      expect(described_class.extract_text_from_tempfile(tempfile, extension: 'docx')).to eq('Workspace manual')
      expect(described_class).to have_received(:capture_command_with_limits).with('python3', '-c', kind_of(String), 'docx', tempfile.path)
    ensure
      tempfile&.close!
    end

    it 'extracts legacy Word documents through the no-key strings fallback' do
      tempfile = Tempfile.new(['manual', '.doc'])
      status = instance_double(Process::Status, success?: true, exitstatus: 0)
      allow(described_class).to receive(:capture_command_with_limits).and_return(["Legacy manual\n", '', status, false])

      expect(described_class.extract_text_from_tempfile(tempfile, extension: 'doc')).to eq('Legacy manual')
      expect(described_class).to have_received(:capture_command_with_limits).with('strings', '-n', '3', tempfile.path)
    ensure
      tempfile&.close!
    end

    it 'returns nil when fallback extraction times out' do
      tempfile = Tempfile.new(['manual', '.doc'])
      allow(described_class).to receive(:capture_command_with_limits).and_return(['', 'timeout', nil, true])

      expect(described_class.extract_text_from_tempfile(tempfile, extension: 'doc')).to be_nil
    ensure
      tempfile&.close!
    end

    it 'keeps office fallback extraction globally bounded' do
      script = described_class.office_text_extractor_script

      expect(script).to include('XML_TOTAL_READ_LIMIT')
      expect(script).to include('MAX_XML_MEMBERS')
      expect(script).to include('MAX_XLSX_CHUNKS')
      expect(script).to include('bytes_remaining -= len(data)')
      expect(script).to include('members_remaining -= 1')
      expect(script).to include('if yielded >= MAX_XLSX_CHUNKS:')
      expect(script).not_to include('chunks = []')
    end
  end
end
