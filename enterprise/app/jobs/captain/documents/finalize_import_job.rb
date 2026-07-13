class Captain::Documents::FinalizeImportJob < ApplicationJob
  queue_as :low
  MAX_PENDING_ATTEMPTS = 60
  EMPTY_CRAWL_GRACE_ATTEMPTS = 3
  PENDING_RETRY_DELAY = 5.seconds

  def perform(document_id:, event_type:, **options)
    document = Captain::Document.find(document_id)
    return unless current_import_event?(document, options)
    return handle_failed_event(document, options) if failed_event?(event_type)

    record_provider_failures(document, options)
    return retry_pending_pages(document, event_type, options) if empty_crawl_grace?(document, options[:attempt].to_i)

    finalize_completed_event(document, event_type, options)
  rescue ActiveRecord::RecordNotFound
    nil
  end

  private

  def current_import_event?(document, options)
    return false unless document.current_import_run?(options[:import_run_id])
    return false if document.import_job_id.blank? || options[:job_id].blank?

    document.import_job_id.to_s == options[:job_id].to_s
  end

  def handle_failed_event(document, options)
    record_provider_failures(document, options)
    document.mark_import_failed!(
      options[:error_message].presence || default_failure_message,
      import_run_id: options[:import_run_id]
    )
  end

  def record_provider_failures(document, options)
    failed_urls = fetch_failed_urls(document, options[:job_id])
    return if failed_urls.blank?

    document.record_failed_urls!(failed_urls, import_run_id: options[:import_run_id])
  end

  def empty_crawl_grace?(document, attempt)
    document.pages_total.nil? && document.received_urls.empty? && attempt < EMPTY_CRAWL_GRACE_ATTEMPTS
  end

  def finalize_completed_event(document, event_type, options)
    result = document.finalize_import!(import_run_id: options[:import_run_id])
    return unless result == :pending

    if options[:attempt].to_i < MAX_PENDING_ATTEMPTS
      retry_pending_pages(document, event_type, options)
    else
      document.fail_import_if_pending!('Firecrawl page processing timed out', import_run_id: options[:import_run_id])
    end
  end

  def retry_pending_pages(document, event_type, options)
    self.class.set(wait: PENDING_RETRY_DELAY).perform_later(
      document_id: document.id,
      event_type: event_type,
      job_id: options[:job_id],
      error_message: options[:error_message],
      import_run_id: options[:import_run_id],
      attempt: options[:attempt].to_i + 1
    )
  end

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
