# frozen_string_literal: true

class Captain::Tools::Copilot::WebSearchService < Captain::Tools::Copilot::WebAccessBaseService
  def self.name
    'web_search'
  end

  description 'Search the public web through Firecrawl and return source links with short snippets'
  param :query, type: :string, desc: 'Search query', required: true
  param :limit, type: :integer, desc: 'Maximum number of results, capped by Captain settings', required: false

  def execute(query:, limit: nil)
    ensure_firecrawl_configured!
    ensure_web_tool_enabled!('web_search')

    effective_limit = Llm::RuntimePolicy.web_search_limit(
      preferences: runtime_preferences,
      requested: limit
    )
    response = firecrawl.search(
      query,
      limit: effective_limit,
      sources: ['web'],
      include_domains: Llm::RuntimePolicy.web_allowed_domains(preferences: runtime_preferences),
      exclude_domains: Llm::RuntimePolicy.web_blocked_domains(preferences: runtime_preferences),
      ignore_invalid_urls: true,
      scrape_results: false
    )

    tool_success(
      message: 'Web search completed',
      data: search_payload(query, parsed_firecrawl_response(response), effective_limit)
    )
  rescue StandardError => e
    tool_failure(e, retryable: false)
  end

  private

  def search_payload(query, parsed, limit)
    results = normalize_search_results(parsed).first(limit)

    {
      action: 'web_search',
      provider: 'firecrawl',
      query: query,
      total_count: results.length,
      results: results,
      warning: parsed['warning']
    }.compact
  end

  def normalize_search_results(parsed)
    data = parsed['data']
    entries =
      if data.is_a?(Hash)
        Array(data['web'])
      else
        Array(data)
      end

    entries.filter_map.with_index(1) do |entry, index|
      result = entry.to_h.stringify_keys
      url = result['url'].presence
      next if url.blank?

      validate_public_url!(url)
      {
        rank: index,
        title: result['title'].presence || url,
        url: url,
        description: result['description'].presence || result['snippet'].presence,
        source: 'web'
      }.compact
    rescue ArgumentError
      nil
    end
  end
end
