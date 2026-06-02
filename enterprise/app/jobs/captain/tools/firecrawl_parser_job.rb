class Captain::Tools::FirecrawlParserJob < ApplicationJob
  queue_as :low

  def perform(assistant_id:, payload:, source_document_id: nil)
    assistant = Captain::Assistant.find(assistant_id)
    account = assistant.account
    source_document = account.captain_documents.find_by(id: source_document_id) if source_document_id.present?
    metadata = payload.with_indifferent_access[:metadata] || {}

    canonical_url = normalize_link(metadata['url'])
    document = find_or_initialize_document(account, source_document, canonical_url, assistant)
    return mark_conflicting_page_processed(source_document, canonical_url) if document.blank?

    change_tracking = payload.with_indifferent_access[:changeTracking] || {}

    if document.new_record? && limit_exceeded?(account)
      Rails.logger.info("Document limit exceeded for #{assistant_id}")
      return
    end

    if delta_skip?(source_document, change_tracking)
      source_document.record_change_result!(canonical_url, change_tracking[:changeStatus])
      source_document.mark_page_processed!(canonical_url)
      return
    end

    if delta_removed?(source_document, change_tracking)
      document.destroy! if document.persisted? && source_document&.id != document.id
      source_document.record_change_result!(canonical_url, change_tracking[:changeStatus])
      source_document.mark_page_processed!(canonical_url)
      return
    end

    source_document&.record_change_result!(canonical_url, change_tracking[:changeStatus]) if change_tracking[:changeStatus].present?
    document.update!(document_attributes(payload, metadata, source_document, document, canonical_url, assistant))
    source_document&.mark_page_processed!(canonical_url)
  rescue StandardError => e
    source_document&.record_failed_urls!([canonical_url])
    raise "Failed to parse FireCrawl data: #{e.message}"
  end

  private

  def document_attributes(payload, metadata, source_document, document, canonical_url, assistant)
    attrs = {
      external_link: canonical_url,
      assistant: source_document.present? ? source_document.assistant : assistant,
      source_text: payload.with_indifferent_access[:markdown].to_s,
      content: Captain::Documents::SourceTextExtractor.preview(payload.with_indifferent_access[:markdown]),
      name: metadata['title'].to_s[0..254],
      status: source_document&.id == document.id ? document.status : :available
    }

    return attrs if source_document.blank? || source_document.id == document.id

    attrs[:faq_generation_enabled] = source_document.faq_generation_enabled
    attrs[:visibility] = source_document.visibility
    attrs[:metadata] = (document.metadata || {}).deep_merge(
      'firecrawl' => {
        'provider' => 'firecrawl',
        'root_document_id' => source_document.id,
        'root_url' => source_document.external_link,
        'mode' => source_document.source_mode
      }
    )
    attrs
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

  def mark_conflicting_page_processed(source_document, canonical_url)
    source_document&.mark_page_processed!(canonical_url)
  end

  def normalize_link(raw_url)
    raw_url.to_s.delete_suffix('/')
  end

  def limit_exceeded?(account)
    limits = account.usage_limits[:captain][:documents]
    limits[:current_available].negative? || limits[:current_available].zero?
  end

  def delta_skip?(source_document, change_tracking)
    source_document&.refresh_mode == 'delta' && change_tracking[:changeStatus] == 'same'
  end

  def delta_removed?(source_document, change_tracking)
    source_document&.refresh_mode == 'delta' && change_tracking[:changeStatus] == 'removed'
  end
end
