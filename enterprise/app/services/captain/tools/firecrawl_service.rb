class Captain::Tools::FirecrawlService
  DEFAULT_API_URL = 'https://api.firecrawl.dev/v2'.freeze
  DEFAULT_MAP_LIMIT = 100

  class << self
    def api_key
      ENV['FIRECRAWL_API_KEY'].presence ||
        InstallationConfig.find_by(name: 'CAPTAIN_FIRECRAWL_API_KEY')&.value.presence
    end

    def api_url
      (ENV['FIRECRAWL_API_URL'].presence || DEFAULT_API_URL).delete_suffix('/')
    end

    def configured?
      self_hosted? || api_key.present?
    end

    def self_hosted?
      configured_url = ENV['FIRECRAWL_API_URL'].presence
      configured_url.present? && configured_url.delete_suffix('/') != DEFAULT_API_URL
    end

    def authentication_configured?
      api_key.present?
    end
  end

  def initialize
    @api_key = self.class.api_key
    @api_url = self.class.api_url
    raise 'Missing API key for Firecrawl Cloud' if @api_key.blank? && !self.class.self_hosted?
  end

  def perform(url, webhook_url, crawl_limit = 10, options = {})
    crawl(url, webhook_url, crawl_limit, options)
  rescue StandardError => e
    raise if e.message.start_with?('Failed to crawl URL:')

    raise "Failed to crawl URL: #{e.message.sub('Failed Firecrawl request: ', '')}"
  end

  def scrape(url, options = {})
    post('/scrape', body: scrape_payload(url, options))
  end

  def search(query, options = {})
    post('/search', body: search_payload(query, options))
  end

  def parse_upload(attachment, options = {})
    blob = attachment.respond_to?(:blob) ? attachment.blob : attachment

    Tempfile.create(['firecrawl-upload', file_extension(blob)], binmode: true) do |tempfile|
      blob.download { |chunk| tempfile.write(chunk) }
      tempfile.flush
      tempfile.rewind

      File.open(tempfile.path, 'rb') do |file|
        post_multipart('/parse', body: { file: file, options: parse_options_payload(options).to_json })
      end
    end
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

    parsed_response = parse_json_response(response)
    errors = Array(parsed_response['errors']).pluck('url')
    robots_blocked = Array(parsed_response['robotsBlocked'])

    (errors + robots_blocked).map { |url| url.to_s.delete_suffix('/') }.reject(&:blank?).uniq
  end

  private

  def post(path, body:)
    HTTParty.post(
      "#{@api_url}#{path}",
      body: body,
      headers: json_headers,
      timeout: request_timeout
    )
  rescue StandardError => e
    raise "Failed Firecrawl request: #{e.message}"
  end

  def post_multipart(path, body:)
    HTTParty.post(
      "#{@api_url}#{path}",
      body: body,
      headers: auth_headers,
      multipart: true,
      timeout: request_timeout
    )
  rescue StandardError => e
    raise "Failed Firecrawl request: #{e.message}"
  end

  def get(path)
    HTTParty.get(
      "#{@api_url}#{path}",
      headers: auth_headers,
      timeout: request_timeout
    )
  rescue StandardError => e
    raise "Failed Firecrawl request: #{e.message}"
  end

  def scrape_payload(url, options)
    scrape_options_payload(options).merge(url: url).to_json
  end

  def parse_options_payload(options)
    scrape_options_payload(options).except(:actions, :waitFor, :changeTracking)
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

  def search_payload(query, options)
    payload = {
      query: query,
      limit: options.fetch(:limit, 5),
      sources: search_sources_payload(options[:sources]),
      categories: search_categories_payload(options[:categories]),
      includeDomains: Array(options[:include_domains]).presence,
      excludeDomains: Array(options[:exclude_domains]).presence,
      tbs: options[:tbs],
      location: options[:location],
      country: options.fetch(:country, 'US'),
      timeout: options[:timeout],
      ignoreInvalidURLs: options.fetch(:ignore_invalid_urls, true)
    }.compact

    if options[:scrape_results]
      payload[:scrapeOptions] = nested_scrape_options_payload(
        {
          formats: ['markdown'],
          only_main_content: true,
          remove_base64_images: true
        }.merge(options[:scrape_options].to_h.symbolize_keys)
      )
    end

    payload.to_json
  end

  def search_sources_payload(sources)
    normalized_sources = Array(sources).filter_map do |source|
      normalized = source.respond_to?(:to_h) ? source.to_h.stringify_keys : { 'type' => source.to_s }
      type = normalized['type'].to_s.strip
      next if type.blank?

      normalized.merge('type' => type)
    end

    normalized_sources.presence || [{ 'type' => 'web' }]
  end

  def search_categories_payload(categories)
    Array(categories).filter_map do |category|
      normalized = category.respond_to?(:to_h) ? category.to_h.stringify_keys : { 'type' => category.to_s }
      type = normalized['type'].to_s.strip
      next if type.blank?

      normalized.merge('type' => type)
    end.presence
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
      scrapeOptions: nested_scrape_options_payload(options)
    }.merge(crawl_root_options_payload(options)).compact.to_json
  end

  def crawl_root_options_payload(options)
    {
      zeroDataRetention: options[:zero_data_retention],
      integration: options[:integration],
      origin: options[:origin]
    }.compact
  end

  def batch_scrape_payload(urls, webhook_url, options = {})
    scrape_options_payload(options).merge(urls: urls, webhook: webhook_payload(webhook_url)).to_json
  end

  def compact_payload(payload)
    payload.compact
  end

  def formats_for_options(options)
    formats = Array(options[:formats]).presence || ['markdown']
    return formats unless options[:change_tracking]

    formats << change_tracking_format(options)
    formats
  end

  def scrape_options_payload(options)
    {
      formats: formats_for_options(options),
      onlyMainContent: options.fetch(:only_main_content, true),
      parsers: options[:parsers],
      timeout: options[:timeout],
      includeTags: options[:include_tags],
      excludeTags: options[:exclude_tags],
      removeBase64Images: options[:remove_base64_images],
      skipTlsVerification: options[:skip_tls_verification],
      blockAds: options[:block_ads],
      proxy: options[:proxy],
      maxAge: options[:max_age],
      minAge: options[:min_age],
      storeInCache: options[:store_in_cache],
      zeroDataRetention: options[:zero_data_retention],
      integration: options[:integration],
      origin: options[:origin],
      waitFor: options[:wait_for],
      actions: options[:actions]
    }.compact
  end

  def nested_scrape_options_payload(options)
    scrape_options_payload(options).except(:zeroDataRetention, :integration, :origin)
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

  def auth_headers
    return {} if @api_key.blank?

    { 'Authorization' => "Bearer #{@api_key}" }
  end

  def json_headers
    auth_headers.merge('Content-Type' => 'application/json')
  end

  def request_timeout
    ENV.fetch('FIRECRAWL_REQUEST_TIMEOUT', 120).to_i
  end

  def file_extension(blob)
    extension = blob.filename.extension_without_delimiter.to_s.downcase
    extension.present? ? ".#{extension}" : ''
  end

  def parse_json_response(response)
    parsed = response.respond_to?(:parsed_response) ? response.parsed_response : response
    return parsed if parsed.is_a?(Hash)
    return {} if parsed.blank?

    JSON.parse(parsed)
  rescue JSON::ParserError
    {}
  end
end
