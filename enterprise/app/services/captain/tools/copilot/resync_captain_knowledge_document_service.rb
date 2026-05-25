# frozen_string_literal: true

class Captain::Tools::Copilot::ResyncCaptainKnowledgeDocumentService < Captain::Tools::Copilot::CaptainKnowledgeAdminTool
  def self.name
    'resync_captain_knowledge_document'
  end

  description 'Reindex/resync a source Captain knowledge document. Requires operator confirmation.'
  param :document_id, type: :integer, desc: 'Captain source document ID', required: true
  param :refresh_mode, type: :string, desc: 'Optional refresh mode: full, delta, retry_failed. Defaults to full.', required: false

  def execute(document_id:, refresh_mode: nil)
    ensure_account_administrator!

    document = find_source_document!(document_id)
    mode = normalize_resync_mode(refresh_mode)
    validate_resync!(document, mode)

    before_payload = document_payload(document, include_details: true)
    document.prepare_for_resync!(refresh_mode: mode)
    Captain::Documents::CrawlJob.perform_later(document)

    formatted_payload(
      action: 'resync_captain_knowledge_document',
      document: document_payload(document.reload, include_details: true),
      previous_document: before_payload,
      refresh_mode: mode
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def validate_resync!(document, mode)
    raise ArgumentError, 'Derived documents cannot be resynced directly' if document.derived_document?
    raise ArgumentError, 'retry_failed requires failed URLs' if mode == 'retry_failed' && document.failed_urls.blank?

    if mode == 'delta' && %w[pdf_upload file_upload].include?(document.source_mode)
      raise ArgumentError, 'Delta refresh is not available for uploaded documents'
    end

    require_firecrawl_if_needed!(document.source_mode)
  end
end
