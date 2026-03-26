class Captain::Tools::FirecrawlService
  DEFAULT_API_URL = 'https://api.firecrawl.dev/v2'.freeze
  DEFAULT_MAP_LIMIT = 100.freeze

  class << self
    def api_key
      ENV['FIRECRAWL_API_KEY'].presence ||
        InstallationConfig.find_by(name: 'CAPTAIN_FIRECRAWL_API_KEY')&.value.presence
    end

    def api_url
      (ENV['FIRECRAWL_API_URL'].presence || DEFAULT_API_URL).delete_suffix('/')
    end

    def configured?
      api_key.present?
    end
  end

  def initialize
    @api_key = self.class.api_key
    @api_url = self.class.api_url
    raise 'Missing API key' if @api_key.blank?
  end

  def perform(url, webhook_url, crawl_limit = 10, options = {})
    crawl(url, webhook_url, crawl_limit, options)
  rescue StandardError => e
    raise "Failed to crawl URL: #{e.message.sub('Failed Firecrawl request: ', '')}"
  end

  def scrape(url, options = {})
    post('/scrape', body: scrape_payload(url, options))
  end

  def map(url, options = {})
    post('/map', body: map_payload(url, options))
  end

  def crawl(url, webhook_url, crawl_limit = 10, options = {})
    post('/crawl', body: crawl_payload(url, webhook_url, crawl_limit, options))
  rescue StandardError => e
    raise "Failed to crawl URL: #{e.message.sub('Failed Firecrawl request: ', '')}"
  end

  def batch_scrape(urls, webhook_url, options = {})
    post('/batch/scrape', body: batch_scrape_payload(urls, webhook_url, options))
  rescue StandardError => e
    raise "Failed to batch scrape URLs: #{e.message.sub('Failed Firecrawl request: ', '')}"
  end

  def failed_urls_for_job(job_id, source_mode, refresh_mode = 'full')
    response = if batch_scrape_mode?(source_mode, refresh_mode)
                 get("/batch/scrape/#{job_id}/errors")
               else
                 get("/crawl/#{job_id}/errors")
               end

    parsed_response = response.parsed_response || {}
    errors = Array(parsed_response['errors']).map { |item| item['url'] }
    robots_blocked = Array(parsed_response['robotsBlocked'])

    (errors + robots_blocked).map { |url| url.to_s.delete_suffix('/') }.reject(&:blank?).uniq
  end

  private

  def post(path, body:)
    HTTParty.post(
      "#{@api_url}#{path}",
      body: body,
      headers: headers
    )
  rescue StandardError => e
    raise "Failed Firecrawl request: #{e.message}"
  end

  def get(path)
    HTTParty.get(
      "#{@api_url}#{path}",
      headers: headers
    )
  rescue StandardError => e
    raise "Failed Firecrawl request: #{e.message}"
  end

  def scrape_payload(url, options)
    {
      url: url,
      formats: formats_for_options(options),
      onlyMainContent: options.fetch(:only_main_content, true)
    }.merge(compact_payload(options.slice(:changeTracking, :waitFor, :actions))).to_json
  end

  def map_payload(url, options)
    {
      url: url,
      sitemap: options.fetch(:sitemap, 'include'),
      includeSubdomains: options.fetch(:allow_subdomains, false),
      ignoreQueryParameters: options.fetch(:ignore_query_parameters, true),
      ignoreCache: options.fetch(:ignore_cache, false),
      limit: options.fetch(:limit, DEFAULT_MAP_LIMIT)
    }.merge(compact_payload(search: options[:search])).to_json
  end

  def crawl_payload(url, webhook_url, crawl_limit, options = {})
    {
      url: url,
      limit: crawl_limit,
      webhook: webhook_payload(webhook_url),
      sitemap: options.fetch(:sitemap, 'include'),
      crawlEntireDomain: options.fetch(:crawl_entire_domain, false),
      allowSubdomains: options.fetch(:allow_subdomains, false),
      ignoreQueryParameters: options.fetch(:ignore_query_parameters, true),
      includePaths: Array(options[:include_paths]).presence,
      excludePaths: Array(options[:exclude_paths]).presence,
      maxDiscoveryDepth: options[:max_discovery_depth],
      scrapeOptions: {
        onlyMainContent: options.fetch(:only_main_content, true),
        formats: formats_for_options(options)
      }
    }.compact.to_json
  end

  def batch_scrape_payload(urls, webhook_url, options = {})
    {
      urls: urls,
      webhook: webhook_payload(webhook_url),
      formats: formats_for_options(options),
      onlyMainContent: options.fetch(:only_main_content, true)
    }.to_json
  end

  def compact_payload(payload)
    payload.compact
  end

  def formats_for_options(options)
    formats = ['markdown']
    return formats unless options[:change_tracking]

    formats << change_tracking_format(options)
    formats
  end

  def change_tracking_format(options)
    {
      type: 'changeTracking',
      tag: options[:change_tracking_tag]
    }.merge(compact_payload(modes: Array(options[:change_tracking_modes]).presence))
  end

  def webhook_payload(webhook_url)
    {
      url: webhook_url,
      events: %w[started page completed failed]
    }
  end

  def batch_scrape_mode?(source_mode, refresh_mode)
    refresh_mode.to_s == 'retry_failed' || source_mode.to_s == 'selected_pages'
  end

  def headers
    {
      'Authorization' => "Bearer #{@api_key}",
      'Content-Type' => 'application/json'
    }
  end
end
