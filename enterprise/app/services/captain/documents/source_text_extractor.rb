require 'open3'

class Captain::Documents::SourceTextExtractor
  PREVIEW_LENGTH = 200_000
  TEXT_CONTENT_TYPE_PREFIXES = %w[text/].freeze
  TEXT_CONTENT_TYPES = %w[
    application/json
    application/xml
    application/yaml
    application/x-yaml
    application/rtf
    application/x-rtf
  ].freeze
  TEXT_EXTENSIONS = %w[txt text md markdown csv json xml yaml yml html htm rtf].freeze

  def self.preview(text)
    text.to_s[0...PREVIEW_LENGTH]
  end

  def self.text_content_type?(content_type)
    normalized_content_type = content_type.to_s.split(';').first.to_s.strip.downcase
    return true if TEXT_CONTENT_TYPE_PREFIXES.any? { |prefix| normalized_content_type.start_with?(prefix) }

    TEXT_CONTENT_TYPES.include?(normalized_content_type)
  end

  def self.text_extension?(extension)
    TEXT_EXTENSIONS.include?(extension.to_s.downcase.delete_prefix('.'))
  end

  def self.pdf_content_type?(content_type)
    content_type.to_s.split(';').first.to_s.strip.downcase == 'application/pdf'
  end

  def self.extract_text_from_tempfile(tempfile, extension: nil, content_type: nil)
    return extract_pdf_text_from_path(tempfile.path) if extension.to_s.downcase.delete_prefix('.') == 'pdf' || pdf_content_type?(content_type)

    return unless text_extension?(extension) || text_content_type?(content_type)

    tempfile.rewind
    preview(tempfile.read.to_s.force_encoding(Encoding::UTF_8).scrub.strip)
  end

  def self.extract_pdf_text_from_path(path)
    stdout, stderr, status = Open3.capture3('pdftotext', '-layout', path, '-')
    return normalize_text(stdout) if status.success? && stdout.present?

    Rails.logger.warn(
      '[CAPTAIN][DOCUMENTS] PDF source text extraction skipped ' \
      "status=#{status.exitstatus} error=#{stderr.to_s.squish}"
    )
    nil
  rescue Errno::ENOENT
    Rails.logger.warn('[CAPTAIN][DOCUMENTS] PDF source text extraction skipped because pdftotext is not installed')
    nil
  end

  def self.normalize_text(text)
    text.to_s.gsub(/\r\n?/, "\n").strip
  end

  def initialize(document)
    @document = document
  end

  def extract_pdf_text
    return unless document.pdf_file.attached?

    with_attachment_tempfile(document.pdf_file) do |temp_file|
      self.class.extract_text_from_tempfile(temp_file, extension: 'pdf', content_type: document.pdf_file.blob.content_type)
    end
  end

  def extract_source_file_text
    return unless document.source_file.attached?

    with_attachment_tempfile(document.source_file) do |temp_file|
      self.class.extract_text_from_tempfile(
        temp_file,
        extension: File.extname(document.source_file.filename.to_s),
        content_type: document.source_file.blob.content_type
      )
    end
  end

  private

  attr_reader :document

  def with_attachment_tempfile(attachment)
    extension = File.extname(attachment.filename.to_s).presence || '.tmp'

    Tempfile.create(['captain-document', extension], binmode: true) do |temp_file|
      attachment.blob.open do |blob_file|
        IO.copy_stream(blob_file, temp_file)
      end
      temp_file.flush
      temp_file.rewind

      yield temp_file
    end
  end
end
