require 'open3'

class Captain::Documents::SourceTextExtractor
  PREVIEW_LENGTH = 200_000
  COMMAND_TIMEOUT_SECONDS = 10
  STDERR_PREVIEW_LENGTH = 4_096
  OFFICE_XML_READ_LIMIT = 2_000_000
  OFFICE_XML_TOTAL_READ_LIMIT = 4_000_000
  OFFICE_MAX_XML_MEMBERS = 64
  OFFICE_MAX_XLSX_CHUNKS = 2_000
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
  OFFICE_CONTENT_TYPE_EXTENSIONS = {
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document' => 'docx',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' => 'xlsx',
    'application/vnd.ms-excel' => 'xls',
    'application/vnd.oasis.opendocument.text' => 'odt',
    'application/msword' => 'doc'
  }.freeze
  OFFICE_EXTENSIONS = %w[docx xlsx odt].freeze
  LEGACY_DOCUMENT_EXTENSIONS = %w[doc xls].freeze
  FALLBACK_CONTENT_TYPES = (TEXT_CONTENT_TYPES + OFFICE_CONTENT_TYPE_EXTENSIONS.keys + %w[
    application/pdf
    application/octet-stream
  ]).uniq.freeze

  def self.preview(text)
    text.to_s[0...PREVIEW_LENGTH]
  end

  def self.text_content_type?(content_type)
    normalized_type = normalize_content_type(content_type)
    return true if TEXT_CONTENT_TYPE_PREFIXES.any? { |prefix| normalized_type.start_with?(prefix) }

    TEXT_CONTENT_TYPES.include?(normalized_type)
  end

  def self.text_extension?(extension)
    TEXT_EXTENSIONS.include?(extension.to_s.downcase.delete_prefix('.'))
  end

  def self.pdf_content_type?(content_type)
    normalize_content_type(content_type) == 'application/pdf'
  end

  def self.extract_text_from_tempfile(tempfile, extension: nil, content_type: nil)
    normalized_extension = extension_for(extension, content_type)

    return extract_pdf_text_from_path(tempfile.path) if normalized_extension == 'pdf' || pdf_content_type?(content_type)

    if text_extension?(normalized_extension) || text_content_type?(content_type)
      tempfile.rewind
      return preview(tempfile.read.to_s.force_encoding(Encoding::UTF_8).scrub.strip)
    end

    return extract_office_text_from_path(tempfile.path, normalized_extension) if OFFICE_EXTENSIONS.include?(normalized_extension)
    return extract_legacy_document_text_from_path(tempfile.path) if LEGACY_DOCUMENT_EXTENSIONS.include?(normalized_extension)
  end

  def self.extension_for(extension, content_type)
    normalized_extension = extension.to_s.downcase.delete_prefix('.')
    return normalized_extension if normalized_extension.present?

    OFFICE_CONTENT_TYPE_EXTENSIONS[normalize_content_type(content_type)]
  end

  def self.extract_pdf_text_from_path(path)
    stdout, stderr, status, timed_out = capture_command_with_limits('pdftotext', '-layout', path, '-')
    return normalize_text(stdout) if status&.success? && stdout.present?

    Rails.logger.warn(
      '[CAPTAIN][DOCUMENTS] PDF source text extraction skipped ' \
      "status=#{command_status(status, timed_out)} error=#{stderr.to_s.squish}"
    )
    nil
  rescue Errno::ENOENT
    Rails.logger.warn('[CAPTAIN][DOCUMENTS] PDF source text extraction skipped because pdftotext is not installed')
    nil
  end

  def self.extract_office_text_from_path(path, extension)
    stdout, stderr, status, timed_out = capture_command_with_limits('python3', '-c', office_text_extractor_script, extension, path)
    return preview(normalize_text(stdout)) if status&.success? && stdout.present?

    Rails.logger.warn(
      '[CAPTAIN][DOCUMENTS] Office source text extraction skipped ' \
      "extension=#{extension} status=#{command_status(status, timed_out)} error=#{stderr.to_s.squish}"
    )
    nil
  rescue Errno::ENOENT
    Rails.logger.warn('[CAPTAIN][DOCUMENTS] Office source text extraction skipped because python3 is not installed')
    nil
  end

  def self.extract_legacy_document_text_from_path(path)
    stdout, stderr, status, timed_out = capture_command_with_limits('strings', '-n', '3', path)
    return preview(normalize_text(stdout)) if status&.success? && stdout.present?

    Rails.logger.warn(
      '[CAPTAIN][DOCUMENTS] Legacy document source text extraction skipped ' \
      "status=#{command_status(status, timed_out)} error=#{stderr.to_s.squish}"
    )
    nil
  rescue Errno::ENOENT
    Rails.logger.warn('[CAPTAIN][DOCUMENTS] Legacy document source text extraction skipped because strings is not installed')
    nil
  end

  def self.capture_command_with_limits(*command)
    stdout_buffer = +''
    stderr_buffer = +''
    timed_out = false

    Open3.popen3(*command) do |stdin, stdout, stderr, wait_thread|
      stdin.close
      stdout_reader = Thread.new { drain_stream(stdout, stdout_buffer, PREVIEW_LENGTH) }
      stderr_reader = Thread.new { drain_stream(stderr, stderr_buffer, STDERR_PREVIEW_LENGTH) }

      unless wait_thread.join(COMMAND_TIMEOUT_SECONDS)
        timed_out = true
        terminate_process(wait_thread.pid)
      end

      [stdout_reader, stderr_reader].each(&:join)
      return [stdout_buffer, stderr_buffer, wait_thread.value, timed_out]
    end
  end

  def self.drain_stream(stream, buffer, max_bytes)
    loop do
      chunk = stream.readpartial(4096)
      remaining = max_bytes - buffer.bytesize
      buffer << chunk.byteslice(0, remaining) if remaining.positive?
    end
  rescue IOError
    buffer
  end

  def self.terminate_process(pid)
    Process.kill('TERM', pid)
  rescue Errno::ESRCH
    nil
  ensure
    sleep 0.1
    begin
      Process.kill('KILL', pid)
    rescue Errno::ESRCH
      nil
    end
  end

  def self.command_status(status, timed_out)
    return 'timeout' if timed_out

    status&.exitstatus || 'unknown'
  end

  def self.normalize_content_type(content_type)
    content_type.to_s.split(';').first.to_s.strip.downcase
  end

  def self.normalize_text(text)
    text.to_s.gsub(/\r\n?/, "\n").strip
  end

  def self.office_text_extractor_script
    <<~PYTHON
      import html
      import re
      import sys
      import zipfile

      KIND, PATH = sys.argv[1], sys.argv[2]
      OUTPUT_LIMIT = #{PREVIEW_LENGTH}
      XML_READ_LIMIT = #{OFFICE_XML_READ_LIMIT}
      XML_TOTAL_READ_LIMIT = #{OFFICE_XML_TOTAL_READ_LIMIT}
      MAX_XML_MEMBERS = #{OFFICE_MAX_XML_MEMBERS}
      MAX_XLSX_CHUNKS = #{OFFICE_MAX_XLSX_CHUNKS}
      bytes_remaining = XML_TOTAL_READ_LIMIT
      members_remaining = MAX_XML_MEMBERS

      def read_member(archive, name):
          global bytes_remaining, members_remaining
          if members_remaining <= 0 or bytes_remaining <= 0:
              return b''
          read_limit = min(XML_READ_LIMIT, bytes_remaining)
          with archive.open(name) as member:
              data = member.read(read_limit + 1)[:read_limit]
          members_remaining -= 1
          bytes_remaining -= len(data)
          return data

      def xml_text(xml):
          text = xml.decode('utf-8', 'ignore')
          text = re.sub(r'<(w:br|br)[^>]*/?>', '\\n', text)
          text = re.sub(r'</(w:p|p|text:p|row)>', '\\n', text)
          text = re.sub(r'<[^>]+>', ' ', text)
          text = html.unescape(text)
          text = re.sub(r'[ \\t]+', ' ', text)
          text = re.sub(r'\\n\\s*', '\\n', text)
          return text.strip()[:OUTPUT_LIMIT]

      def emit(chunks):
          written = 0
          for chunk in chunks:
              if not chunk:
                  continue
              chunk = chunk[:OUTPUT_LIMIT - written]
              if not chunk:
                  break
              print(chunk)
              written += len(chunk)
              if written >= OUTPUT_LIMIT:
                  break

      with zipfile.ZipFile(PATH) as archive:
          names = archive.namelist()
          if KIND == 'docx':
              targets = [name for name in names if name == 'word/document.xml' or name.startswith(('word/header', 'word/footer'))]
              emit(xml_text(read_member(archive, name)) for name in targets)
          elif KIND == 'odt':
              emit([xml_text(read_member(archive, 'content.xml'))] if 'content.xml' in names else [])
          elif KIND == 'xlsx':
              shared = []
              if 'xl/sharedStrings.xml' in names:
                  shared_xml = read_member(archive, 'xl/sharedStrings.xml').decode('utf-8', 'ignore')
                  shared = [xml_text(item.encode('utf-8')) for item in re.findall(r'<si[^>]*>(.*?)</si>', shared_xml, re.S)]
              def xlsx_chunks():
                  yielded = 0
                  for name in names:
                      if not name.startswith('xl/worksheets/sheet') or not name.endswith('.xml'):
                          continue
                      sheet = read_member(archive, name).decode('utf-8', 'ignore')
                      if not sheet:
                          return
                      for match in re.finditer(r'<c[^>]*t="s"[^>]*>.*?<v>(\\d+)</v>.*?</c>', sheet, re.S):
                          if yielded >= MAX_XLSX_CHUNKS:
                              return
                          index = int(match.group(1))
                          if index < len(shared):
                              yielded += 1
                              yield shared[index]
                      if yielded >= MAX_XLSX_CHUNKS:
                          return
                      yielded += 1
                      yield xml_text(sheet.encode('utf-8'))

              emit(xlsx_chunks())
    PYTHON
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
