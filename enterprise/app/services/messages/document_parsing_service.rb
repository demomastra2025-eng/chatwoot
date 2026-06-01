# frozen_string_literal: true

class Messages::DocumentParsingService
  SUPPORTED_FIRECRAWL_EXTENSIONS = %w[html htm pdf docx doc odt rtf xlsx xls].freeze
  SUPPORTED_LOCAL_TEXT_EXTENSIONS = %w[txt csv json].freeze
  SUPPORTED_LOCAL_TEXT_CONTENT_TYPES = %w[text/plain text/csv application/json].freeze
  TERMINAL_STATUSES = %w[completed failed unsupported too_large disabled provider_missing empty].freeze

  class ProviderError < StandardError; end

  attr_reader :attachment, :message, :account

  class << self
    def enabled_for_account?(account)
      return false if account.blank?
      return false unless account.feature_enabled?('captain_integration')

      Llm::RuntimePolicy.web_access_enabled?(:document_parse, account: account)
    end

    def parseable_attachment?(attachment)
      return false unless supported_attachment?(attachment)
      return true if local_text_supported_attachment?(attachment)

      Captain::Tools::FirecrawlService.configured?
    end

    def supported_attachment?(attachment)
      return false unless attachment&.file_type.to_s == 'file'
      return false unless attachment.file.attached?

      firecrawl_supported_attachment?(attachment) || local_text_supported_attachment?(attachment)
    end

    def pending_attachment?(attachment, account: nil)
      account ||= attachment&.message&.account
      return false unless enabled_for_account?(account)
      return false unless parseable_attachment?(attachment)
      return false if extracted_text(attachment).present?

      TERMINAL_STATUSES.exclude?(document_parse_status(attachment))
    end

    def extracted_text(attachment)
      attachment&.meta.to_h['parsed_text'].presence || attachment&.meta.to_h['transcribed_text'].presence
    end

    def document_parse_status(attachment)
      attachment&.meta.to_h.dig('document_parse', 'status').to_s
    end

    def mark_failed(attachment_id, error)
      attachment = Attachment.find_by(id: attachment_id)
      return if attachment.blank?

      new(attachment).mark_failed!(error)
    end

    def firecrawl_supported_attachment?(attachment)
      supported_firecrawl_extension?(extension_for(attachment))
    end

    def local_text_supported_attachment?(attachment)
      extension = extension_for(attachment)
      return true if SUPPORTED_LOCAL_TEXT_EXTENSIONS.include?(extension)

      SUPPORTED_LOCAL_TEXT_CONTENT_TYPES.include?(content_type_for(attachment))
    end

    private

    def supported_firecrawl_extension?(extension)
      SUPPORTED_FIRECRAWL_EXTENSIONS.include?(extension.to_s)
    end

    def extension_for(attachment)
      return '' unless attachment&.file&.attached?

      [
        attachment.extension,
        attachment.file.blob.filename.extension_without_delimiter,
        extension_from_content_type(attachment.file.blob.content_type)
      ].filter_map { |extension| extension.to_s.downcase.presence }.first.to_s
    end

    def content_type_for(attachment)
      attachment&.file&.blob&.content_type.to_s.downcase.split(';').first
    end

    def extension_from_content_type(content_type)
      {
        'text/html' => 'html',
        'application/pdf' => 'pdf',
        'application/msword' => 'doc',
        'application/vnd.ms-excel' => 'xls',
        'application/rtf' => 'rtf',
        'text/rtf' => 'rtf',
        'application/vnd.oasis.opendocument.text' => 'odt',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document' => 'docx',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' => 'xlsx'
      }[content_type.to_s.downcase.split(';').first]
    end
  end

  def initialize(attachment)
    @attachment = attachment
    @message = attachment.message
    @account = message&.account
  end

  def perform
    return { error: 'Message not found' } if message.blank?
    return { success: true, text: cached_text } if cached_text.present?
    return mark_skipped('disabled') unless self.class.enabled_for_account?(account)
    return mark_skipped('unsupported') unless self.class.supported_attachment?(attachment)
    return mark_skipped('provider_missing') unless parser_available?
    return mark_skipped('too_large') if too_large?

    parsed = parse_document
    text, truncated = truncate_text(parsed[:text])
    return mark_skipped('empty') if text.blank?

    update_parsed_text!(
      text: text,
      metadata: parsed[:metadata],
      parser: parsed[:parser],
      truncated: truncated
    )

    { success: true, text: text, metadata: parsed[:metadata] }
  end

  def mark_failed!(error)
    update_meta!(
      'document_parse' => document_parse_metadata(
        status: 'failed',
        error: error.message.to_s.truncate(300)
      )
    )
    message.reload.send_update_event
  end

  private

  def cached_text
    self.class.extracted_text(attachment)
  end

  def parser_available?
    return true if local_text_attachment?

    Captain::Tools::FirecrawlService.configured?
  end

  def too_large?
    attachment.file.blob.byte_size.to_i > Llm::RuntimePolicy.web_document_parse_max_file_bytes
  end

  def parse_document
    return parse_local_text if local_text_attachment?

    parse_with_firecrawl
  end

  def local_text_attachment?
    self.class.local_text_supported_attachment?(attachment)
  end

  def parse_local_text
    {
      parser: 'local_text',
      text: read_local_text,
      metadata: {
        sourceFile: attachment.file.blob.filename.to_s,
        contentType: attachment.file.blob.content_type
      }.compact
    }
  end

  def parse_with_firecrawl
    response = Captain::Tools::FirecrawlService.new.parse_upload(
      attachment.file.blob,
      formats: ['markdown'],
      only_main_content: true,
      remove_base64_images: true,
      timeout: 60_000
    )
    data = firecrawl_response_data!(response)

    {
      parser: 'firecrawl',
      text: data[:markdown].presence || data[:content].presence || data[:text].presence || data[:summary].presence,
      metadata: data[:metadata].to_h
    }
  rescue StandardError => e
    raise ProviderError, "Failed Firecrawl document parse: #{e.message.sub('Failed Firecrawl request: ', '')}"
  end

  def firecrawl_response_data!(response)
    payload = response.respond_to?(:parsed_response) ? response.parsed_response : response
    payload = JSON.parse(payload) if payload.is_a?(String)
    payload = payload.with_indifferent_access if payload.respond_to?(:with_indifferent_access)
    payload ||= {}

    error_message = payload[:error].presence || payload.dig(:data, :metadata, :error).presence
    unsuccessful = response.respond_to?(:success?) && !response.success?
    raise(error_message || response_code(response) || 'Firecrawl parse failed') if unsuccessful || payload[:success] == false

    data = (payload[:data].presence || payload).with_indifferent_access
    raise 'Firecrawl did not return document text' if data[:markdown].blank? && data[:content].blank? && data[:text].blank? && data[:summary].blank?

    data
  rescue JSON::ParserError => e
    raise "Firecrawl returned invalid JSON: #{e.message}"
  end

  def response_code(response)
    response.code if response.respond_to?(:code)
  end

  def read_local_text
    max_bytes = Llm::RuntimePolicy.web_document_parse_max_chars(account: account) * 4
    buffer = +''

    attachment.file.blob.download do |chunk|
      buffer << chunk
      break if buffer.bytesize >= max_bytes
    end

    buffer
      .byteslice(0, max_bytes)
      .to_s
      .force_encoding(Encoding::UTF_8)
      .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '')
  end

  def truncate_text(text)
    normalized = text.to_s.strip
    max_chars = Llm::RuntimePolicy.web_document_parse_max_chars(account: account)
    return [normalized, false] if normalized.length <= max_chars

    ["#{normalized.first(max_chars)}\n\n[Document text truncated]", true]
  end

  def update_parsed_text!(text:, metadata:, parser:, truncated:)
    update_meta!(
      'transcribed_text' => text,
      'parsed_text' => text,
      'document_parse' => document_parse_metadata(
        status: 'completed',
        parser: parser,
        chars: text.length,
        truncated: truncated,
        document_metadata: metadata
      )
    )

    Rails.logger.info(
      'Document parsing completed ' \
      "attachment_id=#{attachment.id} message_id=#{message.id} parser=#{parser} chars=#{text.length}"
    )
    message.reload.send_update_event
    message.reindex if ChatwootApp.advanced_search_allowed?
  end

  def mark_skipped(status)
    update_meta!('document_parse' => document_parse_metadata(status: status))
    { error: "Document parsing #{status}" }
  end

  def document_parse_metadata(status:, **extra)
    blob = attachment.file.blob if attachment.file.attached?

    {
      'status' => status,
      'provider' => extra.delete(:parser).presence || 'firecrawl',
      'filename' => blob&.filename.to_s,
      'content_type' => blob&.content_type,
      'file_size' => blob&.byte_size,
      'parsed_at' => Time.current.iso8601
    }.merge(extra.stringify_keys).compact
  end

  def update_meta!(attributes)
    attachment.with_lock do
      current_meta = attachment.reload.meta.to_h
      next_document_parse = current_meta['document_parse'].to_h.merge(attributes.delete('document_parse').to_h)
      attachment.update!(meta: current_meta.merge(attributes).merge('document_parse' => next_document_parse))
    end
  end
end
