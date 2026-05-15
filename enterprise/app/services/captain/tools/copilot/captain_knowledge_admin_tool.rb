# frozen_string_literal: true

class Captain::Tools::Copilot::CaptainKnowledgeAdminTool < Captain::Tools::Copilot::CaptainAssistantAdminTool
  SUPPORTED_SOURCE_MODES = %w[legacy_url selected_pages pdf_url file_url].freeze
  FIRECRAWL_SOURCE_MODES = %w[pdf_url file_url].freeze
  RESYNC_MODES = %w[full delta retry_failed].freeze

  private

  def documents_scope
    account.captain_documents.includes(:assistant).ordered
  end

  def source_documents_scope
    documents_scope.source_documents
  end

  def knowledge_entries_scope
    account.captain_assistant_responses.includes(:assistant, :documentable).ordered
  end

  def find_document!(document_id)
    documents_scope.find(document_id)
  end

  def find_source_document!(document_id)
    source_documents_scope.find(document_id)
  end

  def find_document_for_assistant!(document_id, document_assistant)
    document = find_document!(document_id)
    return document if document.assistant_id == document_assistant.id

    raise ActiveRecord::RecordNotFound, 'Captain document belongs to a different assistant'
  end

  def find_knowledge_entry!(entry_id)
    knowledge_entries_scope.find(entry_id)
  end

  def document_payload(document, include_details: false)
    payload = document_identity_payload(document).merge(document_status_payload(document)).compact
    merge_document_details!(payload, document) if include_details
    payload
  end

  def document_identity_payload(document)
    {
      id: document.id,
      assistant_id: document.assistant_id,
      assistant_name: document.assistant&.name,
      name: redacted_value(document.name),
      source_mode: document.source_mode,
      created_at: document.created_at&.iso8601,
      updated_at: document.updated_at&.iso8601
    }
  end

  def document_status_payload(document)
    {
      status: document.status,
      sync_status: document.sync_status,
      faq_generation_enabled: document.faq_generation_enabled,
      source_document: document.source_document?,
      sendable: document.sendable_file?,
      filename: redacted_value(document.sendable_filename),
      content_type: document.content_type,
      file_size: document.file_size,
      pages_processed: document.pages_processed,
      pages_total: document.pages_total,
      failed_urls_count: document.failed_urls_count,
      last_error: redacted_value(document.last_error),
      last_synced_at: document.last_synced_at&.iso8601
    }
  end

  def merge_document_details!(payload, document)
    payload[:external_link] = redacted_value(document.external_link)
    payload[:display_url] = redacted_value(document.display_url)
    payload[:selected_urls_count] = document.selected_urls_count
    payload[:refresh_mode] = document.refresh_mode
    payload[:source_text_available] = document.source_text.present?
    payload[:source_text_bytes] = document.source_text.to_s.bytesize if document.source_text.present?
    payload[:responses_count] = document.responses.count
  end

  def knowledge_entry_payload(entry, include_body: false)
    payload = knowledge_entry_base_payload(entry)
    merge_entry_preview!(payload, entry)
    merge_entry_body_metadata!(payload, entry) if include_body
    payload
  end

  def knowledge_entry_base_payload(entry)
    {
      id: entry.id,
      assistant_id: entry.assistant_id,
      assistant_name: entry.assistant&.name,
      status: entry.status,
      edited: entry.edited,
      documentable_type: entry.documentable_type,
      documentable_id: safe_documentable_id(entry),
      created_at: entry.created_at&.iso8601,
      updated_at: entry.updated_at&.iso8601
    }.compact
  end

  def merge_entry_body_metadata!(payload, entry)
    payload[:question_bytes] = entry.question.to_s.bytesize
    payload[:answer_bytes] = entry.answer.to_s.bytesize
  end

  def merge_entry_preview!(payload, entry)
    payload[:question_preview] = filtered_marker(entry.question)
    payload[:answer_preview] = filtered_marker(entry.answer)
  end

  def filtered_marker(value)
    value.present? ? '[FILTERED]' : nil
  end

  def safe_documentable_id(entry)
    return unless entry.documentable_type == 'Captain::Document'

    entry.documentable_id
  end

  def create_document_attributes(assistant:, kwargs:)
    source_mode = normalize_source_mode(kwargs[:source_mode])
    require_firecrawl_if_needed!(source_mode)

    {
      assistant: assistant,
      account: account,
      name: kwargs[:name],
      external_link: kwargs[:external_link],
      faq_generation_enabled: cast_boolean(kwargs[:faq_generation_enabled], default: true),
      metadata: document_metadata(source_mode: source_mode, kwargs: kwargs)
    }
  end

  def document_metadata(source_mode:, kwargs:)
    return {} if source_mode.blank? || source_mode == Captain::Document::DEFAULT_SOURCE_MODE

    {
      'firecrawl' => {
        'provider' => Captain::Tools::FirecrawlService.configured? ? 'firecrawl' : 'simple_crawl',
        'mode' => source_mode,
        'source_document' => true,
        'root_url' => kwargs[:external_link],
        'selected_urls' => parse_json_array(kwargs[:selected_urls_json], field_name: 'selected_urls_json', default: []),
        'import_profile' => parse_json_hash(kwargs[:import_profile_json], field_name: 'import_profile_json', default: {}),
        'sync' => { 'status' => 'queued', 'pages_processed' => 0, 'last_error' => nil }
      }
    }
  end

  def normalize_source_mode(source_mode)
    mode = source_mode.presence || Captain::Document::DEFAULT_SOURCE_MODE
    raise ArgumentError, "source_mode must be one of: #{SUPPORTED_SOURCE_MODES.join(', ')}" unless SUPPORTED_SOURCE_MODES.include?(mode)

    mode
  end

  def require_firecrawl_if_needed!(source_mode)
    return unless FIRECRAWL_SOURCE_MODES.include?(source_mode)
    return if Captain::Tools::FirecrawlService.configured?

    raise ArgumentError, 'Firecrawl must be configured for this document source mode'
  end

  def normalize_resync_mode(refresh_mode)
    mode = refresh_mode.presence || 'full'
    raise ArgumentError, "refresh_mode must be one of: #{RESYNC_MODES.join(', ')}" unless RESYNC_MODES.include?(mode)

    mode
  end
end
