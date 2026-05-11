class Captain::Tools::SimplePageCrawlParserJob < ApplicationJob
  queue_as :low

  def perform(assistant_id:, page_link:, source_document_id: nil)
    assistant = Captain::Assistant.find(assistant_id)
    account = assistant.account
    source_document = assistant.documents.find_by(id: source_document_id) if source_document_id.present?

    if limit_exceeded?(account) && !(source_document.present? && normalize_link(page_link) == normalize_link(source_document.external_link))
      Rails.logger.info("Document limit exceeded for #{assistant_id}")
      return
    end

    crawler = Captain::Tools::SimplePageCrawlService.new(page_link)

    page_title = crawler.page_title || ''
    content = crawler.body_text_content || ''

    normalized_link = normalize_link(page_link)
    document = find_or_initialize_document(assistant, source_document, normalized_link)

    document.update!(
      **document_attributes(source_document, document, normalized_link, page_title, content)
    )
    source_document&.mark_page_processed!(normalized_link)
  rescue StandardError => e
    source_document&.record_failed_urls!([page_link])
    raise "Failed to parse data: #{page_link} #{e.message}"
  end

  private

  def document_attributes(source_document, document, normalized_link, page_title, content)
    attrs = {
      external_link: normalized_link,
      name: page_title[0..254],
      source_text: content,
      content: content[0..14_999],
      status: source_document&.id == document.id ? document.status : :available
    }

    return attrs if source_document.blank? || source_document.id == document.id

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

  def find_or_initialize_document(assistant, source_document, normalized_link)
    return source_document if source_document.present? && normalized_link == normalize_link(source_document.external_link)

    assistant.documents.find_or_initialize_by(external_link: normalized_link)
  end

  def normalize_link(raw_link)
    raw_link.to_s.delete_suffix('/')
  end

  def limit_exceeded?(account)
    limits = account.usage_limits[:captain][:documents]
    limits[:current_available].negative? || limits[:current_available].zero?
  end
end
