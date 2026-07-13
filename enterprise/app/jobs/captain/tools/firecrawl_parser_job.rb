class Captain::Tools::FirecrawlParserJob < ApplicationJob
  queue_as :low
  MAX_MARKDOWN_BYTES = 2.megabytes

  def perform(assistant_id:, payload:, source_document_id: nil, import_run_id: nil, job_id: nil)
    context = build_context(assistant_id, payload, source_document_id, import_run_id, job_id)
    return if stale_import_event?(context)
    return unless valid_page_payload?(context)

    process_page(context)
  rescue StandardError => e
    context&.dig(:source_document)&.record_failed_urls!([context&.dig(:canonical_url)], import_run_id: import_run_id)
    raise "Failed to parse FireCrawl data: #{e.message}"
  end

  private

  def build_context(assistant_id, payload, source_document_id, import_run_id, job_id)
    assistant = Captain::Assistant.find(assistant_id)
    account = assistant.account
    source_document = account.captain_documents.find_by(id: source_document_id) if source_document_id.present?
    normalized_payload = payload.with_indifferent_access
    metadata = normalized_payload[:metadata] || {}

    {
      assistant_id: assistant_id,
      assistant: assistant,
      account: account,
      source_document: source_document,
      import_run_id: import_run_id,
      job_id: job_id,
      payload: normalized_payload,
      metadata: metadata,
      canonical_url: normalized_page_url(metadata, source_document),
      change_tracking: normalized_payload[:changeTracking] || {}
    }
  end

  def valid_page_payload?(context)
    if context[:canonical_url].blank?
      context[:source_document]&.record_failed_urls!([raw_page_url(context[:metadata])], import_run_id: context[:import_run_id])
      return false
    end
    return true if context[:payload][:markdown].to_s.bytesize <= MAX_MARKDOWN_BYTES

    context[:source_document]&.record_failed_urls!([context[:canonical_url]], import_run_id: context[:import_run_id])
    false
  end

  def process_page(context)
    context[:document] = find_or_initialize_document(
      context[:account], context[:source_document], context[:canonical_url], context[:assistant]
    )
    return mark_conflicting_page_processed(context[:source_document], context[:canonical_url], context[:import_run_id]) if context[:document].blank?
    return reject_over_limit(context) if context[:document].new_record? && limit_exceeded?(context[:account])
    return if process_delta_skip(context) || process_delta_removal(context)

    persist_page(context)
  end

  def reject_over_limit(context)
    Rails.logger.info("Document limit exceeded for #{context[:assistant_id]}")
    context[:source_document]&.record_failed_urls!([context[:canonical_url]], import_run_id: context[:import_run_id])
  end

  def process_delta_skip(context)
    return false unless delta_skip?(context[:source_document], context[:change_tracking])

    process_import_page(context)
    true
  end

  def process_delta_removal(context)
    return false unless delta_removed?(context[:source_document], context[:change_tracking])
    return true unless process_import_page(context) do
      context[:document].destroy! if context[:document].persisted? && context[:source_document].id != context[:document].id
    end

    true
  end

  def process_import_page(context, &)
    source_document = context[:source_document]
    return yield if source_document.blank? && block_given?
    return true if source_document.blank?

    source_document.process_import_page!(
      context[:canonical_url],
      change_status: context[:change_tracking][:changeStatus],
      import_run_id: context[:import_run_id],
      &
    )
  end

  def persist_page(context)
    process_import_page(context) do
      context[:document].update!(document_attributes(context))
    end
  end

  def document_attributes(context)
    source_document = context[:source_document]
    attrs = base_document_attributes(context)
    return attrs if source_document.blank? || source_document.id == context[:document].id

    attrs[:faq_generation_enabled] = source_document.faq_generation_enabled
    attrs[:visibility] = source_document.visibility
    attrs[:metadata] = derived_document_metadata(context[:document], source_document)
    attrs
  end

  def base_document_attributes(context)
    source_document = context[:source_document]
    document = context[:document]
    {
      external_link: context[:canonical_url],
      assistant: source_document.present? ? source_document.assistant : context[:assistant],
      source_text: context[:payload][:markdown].to_s,
      content: Captain::Documents::SourceTextExtractor.preview(context[:payload][:markdown]),
      name: context[:metadata]['title'].to_s[0..254],
      status: source_document&.id == document.id ? document.status : :available
    }
  end

  def derived_document_metadata(document, source_document)
    (document.metadata || {}).deep_merge(
      'firecrawl' => {
        'provider' => 'firecrawl',
        'root_document_id' => source_document.id,
        'root_url' => source_document.external_link,
        'mode' => source_document.source_mode
      }
    )
  end

  def find_or_initialize_document(account, source_document, canonical_url, assistant)
    return source_document if source_document.present? && canonical_url == normalize_link(source_document.external_link)

    document = account.captain_documents.find_by(external_link: canonical_url)
    return account.captain_documents.new(external_link: canonical_url) if document.blank?
    return document if compatible_document_context?(document, source_document, assistant)

    Rails.logger.warn("[Captain] Skipping conflicting Firecrawl document for #{canonical_url}")
    nil
  end

  def compatible_document_context?(document, source_document, assistant)
    return document.visibility_general? || document.assistant_id == assistant.id if source_document.blank?
    return true if document.metadata&.dig('firecrawl', 'root_document_id').to_s == source_document.id.to_s

    document.assistant_id == source_document.assistant_id && document.visibility == source_document.visibility
  end

  def mark_conflicting_page_processed(source_document, canonical_url, import_run_id)
    source_document&.mark_page_processed!(canonical_url, import_run_id: import_run_id)
  end

  def normalized_page_url(metadata, source_document)
    normalized = Captain::Documents::UrlPolicy.normalize!(raw_page_url(metadata), resolve: false)
    return normalized if source_document.blank?

    allow_subdomains = ActiveModel::Type::Boolean.new.cast(source_document.import_profile['allow_subdomains']) == true
    return normalized if Captain::Documents::UrlPolicy.allowed_for_root?(
      normalized,
      source_document.external_link,
      allow_subdomains: allow_subdomains
    )
  rescue Captain::Documents::UrlPolicy::InvalidUrlError
    nil
  end

  def raw_page_url(metadata)
    metadata['url'].presence || metadata['sourceURL'].presence || metadata['ogUrl'].presence
  end

  def normalize_link(raw_url)
    raw_url.to_s.delete_suffix('/')
  end

  def limit_exceeded?(account)
    limits = account.usage_limits[:captain][:documents]
    limits[:current_available].negative? || limits[:current_available].zero?
  end

  def stale_import_event?(context)
    source_document = context[:source_document]
    return false if source_document.blank?
    return true unless source_document.current_import_run?(context[:import_run_id])
    return true if source_document.import_job_id.blank? || context[:job_id].blank?

    source_document.import_job_id.to_s != context[:job_id].to_s
  end

  def delta_skip?(source_document, change_tracking)
    source_document&.refresh_mode == 'delta' && change_tracking[:changeStatus] == 'same'
  end

  def delta_removed?(source_document, change_tracking)
    source_document&.refresh_mode == 'delta' && change_tracking[:changeStatus] == 'removed'
  end
end
