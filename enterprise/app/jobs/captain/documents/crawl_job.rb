class Captain::Documents::CrawlJob < ApplicationJob
  queue_as :low

  def perform(document)
    return perform_pdf_processing(document) if document.pdf_upload?
    return perform_uploaded_file_import(document) if document.file_upload?
    return perform_retry_failed(document) if document.refresh_mode == 'retry_failed'

    case document.source_mode
    when 'single_page'
      perform_single_page_import(document)
    when 'file_url'
      perform_file_url_import(document)
    when 'selected_pages'
      perform_selected_pages_import(document)
    when 'pdf_url'
      perform_pdf_url_import(document)
    when 'site_import'
      perform_site_import(document)
    else
      perform_legacy_import(document)
    end
  rescue StandardError => e
    document.mark_import_failed!(e.message)
    raise
  end

  private

  include Captain::FirecrawlHelper

  def perform_pdf_processing(document)
    return perform_firecrawl_upload_parse(document, attachment: document.pdf_file) if Captain::Tools::FirecrawlService.configured?

    Captain::Llm::PdfProcessingService.new(document).process
    document.update!(status: :available)
  rescue StandardError => e
    Rails.logger.error I18n.t('captain.documents.pdf_processing_failed', document_id: document.id, error: e.message)
    raise # Re-raise to let job framework handle retry logic
  end

  def perform_single_page_import(document)
    return perform_firecrawl_scrape(document) if Captain::Tools::FirecrawlService.configured?

    enqueue_simple_page_parse(document, document.external_link, total_pages: 1)
  end

  def perform_pdf_url_import(document)
    raise I18n.t('captain.documents.pdf_url_requires_firecrawl') unless Captain::Tools::FirecrawlService.configured?

    perform_firecrawl_scrape(document)
  end

  def perform_file_url_import(document)
    raise I18n.t('captain.documents.file_url_requires_firecrawl') unless Captain::Tools::FirecrawlService.configured?

    perform_firecrawl_scrape(document)
  end

  def perform_uploaded_file_import(document)
    return mark_uploaded_image_available(document) if document.image_upload?

    raise I18n.t('captain.documents.file_upload_requires_firecrawl') unless Captain::Tools::FirecrawlService.configured?

    perform_firecrawl_upload_parse(document, attachment: document.source_file)
  end

  def mark_uploaded_image_available(document)
    document.update!(
      status: :available,
      metadata: (document.metadata || {}).deep_merge(
        'firecrawl' => document.firecrawl_metadata.deep_merge(
          'provider' => 'attachment',
          'sync' => document.firecrawl_sync.merge(
            'status' => 'completed',
            'pages_total' => 1,
            'pages_processed' => 1,
            'processed_urls' => [document.external_link],
            'last_error' => nil,
            'last_synced_at' => Time.current.iso8601
          )
        ),
        'source_text' => {
          'provider' => 'attachment',
          'status' => 'skipped',
          'reason' => 'image_upload',
          'extracted_at' => Time.current.iso8601
        }
      )
    )
  end

  def perform_selected_pages_import(document)
    selected_urls = document.selected_urls.presence
    raise I18n.t('captain.documents.no_selected_pages_error') if selected_urls.blank?

    if Captain::Tools::FirecrawlService.configured?
      perform_firecrawl_batch_scrape(document, selected_urls)
    else
      enqueue_simple_page_parse(document, selected_urls, total_pages: selected_urls.count)
    end
  end

  def perform_site_import(document)
    if Captain::Tools::FirecrawlService.configured?
      perform_firecrawl_crawl(document)
    else
      perform_simple_crawl(document)
    end
  end

  def perform_legacy_import(document)
    if Captain::Tools::FirecrawlService.configured?
      perform_firecrawl_crawl(document)
    else
      perform_simple_crawl(document)
    end
  end

  def perform_firecrawl_scrape(document, target_url: document.external_link)
    document.mark_import_processing!

    response = Captain::Tools::FirecrawlService.new.scrape(
      target_url,
      **firecrawl_document_options(document), **change_tracking_options(document)
    )

    data = firecrawl_response_data!(response)
    data[:metadata] || {}
    change_tracking = data[:changeTracking] || {}

    if delta_refresh?(document)
      document.record_change_result!(document.external_link, change_tracking[:changeStatus])

      if change_tracking[:changeStatus] == 'same'
        document.mark_import_completed!
        return
      end

      if change_tracking[:changeStatus] == 'removed'
        document.mark_import_completed!
        return
      end
    end

    store_firecrawl_document_result!(document, data, source_url: target_url, operation: 'scrape')
  end

  def perform_firecrawl_upload_parse(document, attachment:)
    document.mark_import_processing!

    response = Captain::Tools::FirecrawlService.new.parse_upload(
      attachment,
      **firecrawl_document_options(document)
    )

    data = firecrawl_response_data!(response)
    store_firecrawl_document_result!(document, data, source_url: document.external_link, operation: 'parse')
  end

  def perform_simple_crawl(document)
    page_links = Captain::Tools::SimplePageCrawlService.new(document.external_link).page_links
    all_links = (page_links.to_a + [document.external_link]).uniq
    enqueue_simple_page_parse(document, all_links, total_pages: all_links.count)
  end

  def perform_firecrawl_crawl(document)
    crawl_limit = effective_crawl_limit(document)
    document.mark_import_processing!

    response = Captain::Tools::FirecrawlService
               .new
               .crawl(
                 document.external_link,
                 firecrawl_webhook_url(document),
                 crawl_limit,
                 firecrawl_options(document).merge(change_tracking_options(document))
               )
    document.mark_import_started!(job_id: response.parsed_response['id'])
  end

  def perform_firecrawl_batch_scrape(document, selected_urls)
    document.mark_import_started!(pages_total: selected_urls.count)

    response = Captain::Tools::FirecrawlService
               .new
               .batch_scrape(
                 selected_urls,
                 firecrawl_webhook_url(document),
                 firecrawl_options(document).merge(change_tracking_options(document))
               )

    document.mark_import_started!(job_id: response.parsed_response['id'], pages_total: selected_urls.count)
  end

  def perform_retry_failed(document)
    failed_urls = document.failed_urls
    raise I18n.t('captain.documents.retry_failed_empty_error') if failed_urls.blank?

    if Captain::Tools::FirecrawlService.configured?
      perform_firecrawl_batch_scrape(document, failed_urls)
    else
      enqueue_simple_page_parse(document, failed_urls, total_pages: failed_urls.count)
    end
  end

  def enqueue_simple_page_parse(document, page_links, total_pages:)
    document.mark_import_started!(pages_total: total_pages)

    Array(page_links).each do |page_link|
      Captain::Tools::SimplePageCrawlParserJob.perform_later(
        assistant_id: document.assistant_id,
        page_link: page_link,
        source_document_id: document.id
      )
    end
  end

  def firecrawl_webhook_url(document)
    webhook_url = Rails.application.routes.url_helpers.enterprise_webhooks_firecrawl_url

    "#{webhook_url}?assistant_id=#{document.assistant_id}&document_id=#{document.id}&token=#{generate_firecrawl_token(document.assistant_id,
                                                                                                                      document.account_id)}"
  end

  def effective_crawl_limit(document)
    captain_usage_limits = document.account.usage_limits[:captain] || {}
    document_limit = captain_usage_limits[:documents] || {}
    account_limit = [document_limit[:current_available] || 10, 500].min
    requested_limit = import_profile(document)['max_pages'].presence&.to_i

    return account_limit if requested_limit.blank? || requested_limit <= 0

    [requested_limit, account_limit].min
  end

  def firecrawl_options(document)
    profile = import_profile(document)

    {
      include_paths: profile['include_paths'],
      exclude_paths: profile['exclude_paths'],
      allow_subdomains: profile['allow_subdomains'],
      ignore_query_parameters: profile.fetch('ignore_query_parameters', true),
      only_main_content: profile.fetch('only_main_content', true),
      sitemap: profile.fetch('sitemap', 'include'),
      max_discovery_depth: profile['max_discovery_depth'],
      timeout: profile['timeout'],
      remove_base64_images: profile['remove_base64_images'],
      zero_data_retention: profile['zero_data_retention'],
      store_in_cache: profile['store_in_cache'],
      proxy: profile['proxy']
    }
  end

  def firecrawl_document_options(document)
    firecrawl_options(document).merge(pdf_parser_options(document)).compact
  end

  def pdf_parser_options(document)
    return {} unless document.pdf_document?

    profile = import_profile(document)
    parser = {
      type: 'pdf',
      mode: profile['pdf_parser_mode'].presence || 'auto',
      maxPages: profile['pdf_max_pages'].presence&.to_i
    }.compact

    { parsers: [parser] }
  end

  def import_profile(document)
    document.import_profile
  end

  def delta_refresh?(document)
    document.refresh_mode == 'delta'
  end

  def change_tracking_options(document)
    return {} unless delta_refresh?(document)

    {
      change_tracking: true,
      change_tracking_tag: "captain-document-#{document.id}",
      change_tracking_modes: ['git-diff']
    }
  end

  def firecrawl_response_data!(response)
    payload = response.parsed_response
    payload = JSON.parse(payload) if payload.is_a?(String)
    payload = payload.with_indifferent_access if payload.respond_to?(:with_indifferent_access)
    payload ||= {}

    error_message = payload[:error].presence || payload.dig(:data, :metadata, :error).presence
    unsuccessful = response.respond_to?(:success?) && !response.success?
    raise "Firecrawl import failed: #{error_message || response.code}" if unsuccessful || payload[:success] == false

    data = (payload[:data].presence || payload).with_indifferent_access
    raise 'Firecrawl did not return markdown content' if data[:markdown].blank?

    data
  rescue JSON::ParserError => e
    raise "Firecrawl returned invalid JSON: #{e.message}"
  end

  def store_firecrawl_document_result!(document, data, source_url:, operation:)
    markdown = data[:markdown].to_s
    metadata = (data[:metadata] || {}).with_indifferent_access

    document.update!(
      name: metadata[:title].presence || metadata[:sourceFile].presence || document.name,
      source_text: markdown,
      content: Captain::Documents::SourceTextExtractor.preview(markdown),
      status: :available,
      metadata: firecrawl_result_metadata(document, metadata, markdown, source_url, operation)
    )
  end

  def firecrawl_result_metadata(document, metadata, markdown, source_url, operation)
    (document.metadata || {}).deep_merge(
      'firecrawl' => document.firecrawl_metadata.deep_merge(
        'provider' => 'firecrawl',
        'operation' => operation,
        'document_metadata' => metadata.to_h,
        'sync' => document.firecrawl_sync.merge(
          'status' => 'completed',
          'pages_total' => 1,
          'pages_processed' => 1,
          'processed_urls' => [source_url],
          'last_error' => nil,
          'last_synced_at' => Time.current.iso8601
        )
      ),
      'source_text' => {
        'provider' => 'firecrawl',
        'operation' => operation,
        'status' => 'completed',
        'bytes' => markdown.bytesize,
        'extracted_at' => Time.current.iso8601
      }
    )
  end
end
