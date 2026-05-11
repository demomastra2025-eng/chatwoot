require 'open3'

class Captain::Documents::SourceTextExtractor
  PREVIEW_LENGTH = 200_000

  def self.preview(text)
    text.to_s[0...PREVIEW_LENGTH]
  end

  def initialize(document)
    @document = document
  end

  def extract_pdf_text
    return unless document.pdf_file.attached?

    with_pdf_tempfile do |temp_file|
      stdout, stderr, status = Open3.capture3('pdftotext', '-layout', temp_file.path, '-')
      return normalize_text(stdout) if status.success? && stdout.present?

      Rails.logger.warn(
        '[CAPTAIN][DOCUMENTS] PDF source text extraction skipped ' \
        "document_id=#{document.id} status=#{status.exitstatus} error=#{stderr.to_s.squish}"
      )
      nil
    end
  rescue Errno::ENOENT
    Rails.logger.warn(
      '[CAPTAIN][DOCUMENTS] PDF source text extraction skipped because pdftotext is not installed ' \
      "document_id=#{document.id}"
    )
    nil
  end

  private

  attr_reader :document

  def with_pdf_tempfile
    Tempfile.create(['captain-document', '.pdf'], binmode: true) do |temp_file|
      document.pdf_file.blob.open do |blob_file|
        IO.copy_stream(blob_file, temp_file)
      end
      temp_file.flush
      temp_file.rewind

      yield temp_file
    end
  end

  def normalize_text(text)
    text.to_s.gsub(/\r\n?/, "\n").strip
  end
end
