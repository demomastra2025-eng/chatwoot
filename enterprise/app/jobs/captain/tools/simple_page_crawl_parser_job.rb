class Captain::Tools::SimplePageCrawlParserJob < ApplicationJob
  queue_as :low

  def perform(page_link:, assistant_id: nil, account_id: nil, source_document_id: nil, import_run_id: nil)
    context = build_context(page_link, assistant_id, account_id, source_document_id, import_run_id)
    return if stale_import_run?(context)
    return reject_over_limit(context) if over_limit?(context)
    return unless load_page(context)

    persist_page(context)
  rescue StandardError => e
    context&.dig(:source_document)&.record_failed_urls!([page_link], import_run_id: import_run_id)
    raise "Failed to parse data: #{page_link} #{e.message}"
  end

  private

  def build_context(page_link, assistant_id, account_id, source_document_id, import_run_id)
    assistant = Captain::Assistant.find_by(id: assistant_id) if assistant_id.present?
    account = assistant&.account || Account.find(account_id)
    source_document = account.captain_documents.find_by(id: source_document_id) if source_document_id.present?

    {
      page_link: page_link,
      normalized_link: normalize_link(page_link),
      assistant_id: assistant_id,
      assistant: assistant,
      account: account,
      source_document: source_document,
      import_run_id: import_run_id
    }
  end

  def stale_import_run?(context)
    context[:source_document].present? && !context[:source_document].current_import_run?(context[:import_run_id])
  end

  def over_limit?(context)
    source_document = context[:source_document]
    root_page = source_document.present? && context[:normalized_link] == normalize_link(source_document.external_link)
    limit_exceeded?(context[:account]) && !root_page
  end

  def reject_over_limit(context)
    Rails.logger.info("Document limit exceeded for #{context[:assistant_id]}")
    context[:source_document]&.record_failed_urls!([context[:page_link]], import_run_id: context[:import_run_id])
  end

  def load_page(context)
    crawler = Captain::Tools::SimplePageCrawlService.new(context[:page_link])
    context[:page_title] = crawler.page_title || ''
    context[:content] = crawler.body_text_content || ''
    context[:document] = find_or_initialize_document(
      context[:account], context[:source_document], context[:normalized_link], context[:assistant]
    )
    return true if context[:document].present?

    mark_conflicting_page_processed(context[:source_document], context[:normalized_link], context[:import_run_id])
    false
  end

  def persist_page(context)
    source_document = context[:source_document]
    return context[:document].update!(document_attributes(context)) if source_document.blank?

    source_document.process_import_page!(context[:normalized_link], import_run_id: context[:import_run_id]) do
      context[:document].update!(document_attributes(context))
    end
  end

  def document_attributes(context)
    source_document = context[:source_document]
    attrs = base_document_attributes(context)
    return attrs if source_document.blank? || source_document.id == context[:document].id

    attrs[:visibility] = source_document.visibility
    attrs[:faq_generation_enabled] = source_document.faq_generation_enabled
    attrs[:metadata] = derived_document_metadata(context[:document], source_document)
    attrs
  end

  def base_document_attributes(context)
    source_document = context[:source_document]
    document = context[:document]
    {
      external_link: context[:normalized_link],
      assistant: source_document.present? ? source_document.assistant : context[:assistant],
      name: context[:page_title][0..254],
      source_text: context[:content],
      content: context[:content][0..14_999],
      status: source_document&.id == document.id ? document.status : :available
    }
  end

  def derived_document_metadata(document, source_document)
    (document.metadata || {}).deep_merge(
      'firecrawl' => {
        'provider' => 'simple_crawl',
        'root_document_id' => source_document.id,
        'root_url' => source_document.external_link,
        'mode' => source_document.source_mode
      }
    )
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

  def mark_conflicting_page_processed(source_document, normalized_link, import_run_id)
    source_document&.mark_page_processed!(normalized_link, import_run_id: import_run_id)
  end

  def normalize_link(raw_link)
    raw_link.to_s.delete_suffix('/')
  end

  def limit_exceeded?(account)
    limits = account.usage_limits[:captain][:documents]
    limits[:current_available].negative? || limits[:current_available].zero?
  end
end
