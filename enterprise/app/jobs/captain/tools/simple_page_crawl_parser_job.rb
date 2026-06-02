class Captain::Tools::SimplePageCrawlParserJob < ApplicationJob
  queue_as :low

  def perform(page_link:, assistant_id: nil, account_id: nil, source_document_id: nil)
    assistant = Captain::Assistant.find_by(id: assistant_id) if assistant_id.present?
    account = assistant&.account || Account.find(account_id)
    source_document = account.captain_documents.find_by(id: source_document_id) if source_document_id.present?

    if limit_exceeded?(account) && !(source_document.present? && normalize_link(page_link) == normalize_link(source_document.external_link))
      Rails.logger.info("Document limit exceeded for #{assistant_id}")
      return
    end

    crawler = Captain::Tools::SimplePageCrawlService.new(page_link)

    page_title = crawler.page_title || ''
    content = crawler.body_text_content || ''

    normalized_link = normalize_link(page_link)
    document = find_or_initialize_document(account, source_document, normalized_link, assistant)
    return mark_conflicting_page_processed(source_document, normalized_link) if document.blank?

    document.update!(
      **document_attributes(source_document, document, normalized_link, page_title, content, assistant)
    )
    source_document&.mark_page_processed!(normalized_link)
  rescue StandardError => e
    source_document&.record_failed_urls!([page_link])
    raise "Failed to parse data: #{page_link} #{e.message}"
  end

  private

  def document_attributes(source_document, document, normalized_link, page_title, content, assistant)
    attrs = {
      external_link: normalized_link,
      assistant: source_document.present? ? source_document.assistant : assistant,
      name: page_title[0..254],
      source_text: content,
      content: content[0..14_999],
      status: source_document&.id == document.id ? document.status : :available
    }

    return attrs if source_document.blank? || source_document.id == document.id

    attrs[:visibility] = source_document.visibility
    attrs[:faq_generation_enabled] = source_document.faq_generation_enabled
    attrs[:metadata] = (document.metadata || {}).deep_merge(
      'firecrawl' => {
        'provider' => 'simple_crawl',
        'root_document_id' => source_document.id,
        'root_url' => source_document.external_link,
        'mode' => source_document.source_mode
      }
    )
    attrs
  end

  def find_or_initialize_document(account, source_document, normalized_link, assistant)
    return source_document if source_document.present? && normalized_link == normalize_link(source_document.external_link)

    document = account.captain_documents.find_by(external_link: normalized_link)
    return account.captain_documents.new(external_link: normalized_link) if document.blank?
    return document if compatible_document_context?(document, source_document, assistant)

    Rails.logger.warn("[Captain] Skipping conflicting simple-crawl document for #{normalized_link}")
    nil
  end

  def compatible_document_context?(document, source_document, assistant)
    return document.visibility_general? || (assistant.present? && document.assistant_id == assistant.id) if source_document.blank?
    return true if document.metadata&.dig('firecrawl', 'root_document_id').to_s == source_document.id.to_s

    document.assistant_id == source_document.assistant_id && document.visibility == source_document.visibility
  end

  def mark_conflicting_page_processed(source_document, normalized_link)
    source_document&.mark_page_processed!(normalized_link)
  end

  def normalize_link(raw_link)
    raw_link.to_s.delete_suffix('/')
  end

  def limit_exceeded?(account)
    limits = account.usage_limits[:captain][:documents]
    limits[:current_available].negative? || limits[:current_available].zero?
  end
end
