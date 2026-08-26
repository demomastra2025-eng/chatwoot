# frozen_string_literal: true

class Captain::Tools::Copilot::WebScrapeUrlService < Captain::Tools::Copilot::WebAccessBaseService
  def self.name
    'web_scrape_url'
  end

  description 'Read one approved public URL through Firecrawl and return cleaned page text with source metadata'
  param :url, type: :string, desc: 'Public http or https URL to read', required: true

  def execute(url:)
    ensure_firecrawl_configured!
    ensure_web_tool_enabled!('web_scrape_url')

    uri = validate_public_url!(url)
    response = firecrawl.scrape(
      uri.to_s,
      formats: ['markdown'],
      only_main_content: true,
      remove_base64_images: true
    )

    tool_success(
      message: 'Web page read',
      data: scrape_payload(uri.to_s, parsed_firecrawl_response(response))
    )
  rescue StandardError => e
    tool_failure(e, retryable: false)
  end

  private

  def scrape_payload(url, parsed)
    data = parsed['data'].is_a?(Hash) ? parsed['data'].stringify_keys : parsed
    metadata = data['metadata'].respond_to?(:to_h) ? data['metadata'].to_h.stringify_keys : {}
    max_chars = Llm::RuntimePolicy.web_scrape_max_chars(preferences: runtime_preferences)
    markdown, truncated = truncate_text(data['markdown'].to_s, max_chars)

    {
      action: 'web_scrape_url',
      provider: 'firecrawl',
      url: data['url'].presence || metadata['sourceURL'].presence || url,
      title: metadata['title'].presence || data['title'].presence,
      description: metadata['description'].presence,
      markdown: markdown,
      chars: markdown.length,
      truncated: truncated,
      source: {
        url: metadata['sourceURL'].presence || url,
        fetched_at: Time.current.iso8601
      }
    }.compact
  end
end
