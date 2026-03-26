class Captain::Documents::FinalizeImportJob < ApplicationJob
  queue_as :low

  def perform(document_id:, event_type:, job_id: nil, error_message: nil)
    document = Captain::Document.find(document_id)

    failed_urls = fetch_failed_urls(document, job_id)

    if failed_event?(event_type)
      document.record_failed_urls!(failed_urls) if failed_urls.present?
      document.mark_import_failed!(error_message.presence || default_failure_message)
      return
    end

    document.record_failed_urls!(failed_urls) if failed_urls.present?
    document.mark_import_completed!(failed_urls: failed_urls)
  rescue ActiveRecord::RecordNotFound
    nil
  end

  private

  def fetch_failed_urls(document, job_id)
    return [] if job_id.blank?
    return [] unless Captain::Tools::FirecrawlService.configured?

    Captain::Tools::FirecrawlService.new.failed_urls_for_job(job_id, document.source_mode, document.refresh_mode)
  rescue StandardError => e
    Rails.logger.warn("Failed to fetch Firecrawl errors for document #{document.id}: #{e.message}")
    []
  end

  def failed_event?(event_type)
    event_type.to_s.end_with?('.failed')
  end

  def default_failure_message
    'Firecrawl import failed'
  end
end
