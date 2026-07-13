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

  describe 'real fallback extraction matrix' do
    def archive_tempfile(extension, entries)
      tempfile = Tempfile.new(['captain-source', ".#{extension}"])
      script = <<~PYTHON
        import json
        import sys
        import zipfile

        with zipfile.ZipFile(sys.argv[1], 'w') as archive:
            for entry_name, body in json.loads(sys.argv[2]).items():
                archive.writestr(entry_name, body)
      PYTHON
      _stdout, stderr, status = Open3.capture3('python3', '-c', script, tempfile.path, entries.to_json)
      raise stderr unless status.success?

      tempfile
    end

    it 'extracts every declared text extension from a bounded tempfile', :aggregate_failures do
      tested_extensions = %w[txt text md markdown csv json xml yaml yml html htm rtf]
      expect(tested_extensions).to match_array(described_class::TEXT_EXTENSIONS)

      tested_extensions.each do |extension|
        tempfile = Tempfile.new(['captain-text', ".#{extension}"])
        tempfile.write("#{extension.upcase} fallback marker")
        tempfile.rewind

        extracted = described_class.extract_text_from_tempfile(
          tempfile,
          extension: extension,
          content_type: 'application/octet-stream'
        )
        expect(extracted).to include("#{extension.upcase} fallback marker")
      ensure
        tempfile&.close!
      end
    end

    it 'extracts every declared Office extension from representative files', :aggregate_failures do
      expect(described_class::OFFICE_EXTENSIONS).to match_array(%w[docx odt xlsx])
      expect(described_class::LEGACY_DOCUMENT_EXTENSIONS).to match_array(%w[doc xls])

      archives = {
        'docx' => {
          'word/document.xml' => '<w:document xmlns:w="urn:w"><w:body><w:p><w:r><w:t>DOCX marker</w:t></w:r></w:p></w:body></w:document>'
        },
        'odt' => {
          'content.xml' => '<office:document-content xmlns:office="urn:o" xmlns:text="urn:t"><text:p>ODT marker</text:p></office:document-content>'
        },
        'xlsx' => {
          'xl/sharedStrings.xml' => '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>XLSX marker</t></si></sst>',
          'xl/worksheets/sheet1.xml' =>
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' \
            '<sheetData><row><c t="s"><v>0</v></c></row></sheetData></worksheet>'
        }
      }

      archives.each do |extension, entries|
        tempfile = archive_tempfile(extension, entries)
        extracted = described_class.extract_text_from_tempfile(tempfile, extension: extension)
        expect(extracted).to include("#{extension.upcase} marker")
      ensure
        tempfile&.close!
      end

      %w[doc xls].each do |extension|
        tempfile = Tempfile.new(['captain-legacy', ".#{extension}"])
        tempfile.binmode
        tempfile.write("\x00LEGACY #{extension.upcase} marker\x00")
        tempfile.rewind

        extracted = described_class.extract_text_from_tempfile(tempfile, extension: extension)
        expect(extracted).to include("LEGACY #{extension.upcase} marker")
      ensure
        tempfile&.close!
      end
    end
  end
end
