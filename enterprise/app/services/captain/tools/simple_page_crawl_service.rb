class Captain::Tools::SimplePageCrawlService
  MAX_RESPONSE_BYTES = 2.megabytes
  ALLOWED_CONTENT_TYPES = %w[text/html application/xhtml+xml application/xml text/xml].freeze

  attr_reader :external_link

  def initialize(external_link, root_url: external_link, allow_subdomains: false)
    @external_link = Captain::Documents::UrlPolicy.normalize!(external_link, resolve: false)
    @root_url = Captain::Documents::UrlPolicy.normalize!(root_url, resolve: false)
    @allow_subdomains = allow_subdomains
    @doc = fetch_document
  end

  def page_links
    sitemap? ? extract_links_from_sitemap : extract_links_from_html
  end

  def page_title
    title_element = @doc.at_xpath('//title')
    title_element&.text&.strip
  end

  def body_text_content
    body = @doc.at_xpath('//body')
    return '' if body.blank?

    ReverseMarkdown.convert body, unknown_tags: :bypass, github_flavored: true
  end

  def meta_description
    meta_desc = @doc.at_css('meta[name="description"]')
    return nil unless meta_desc && meta_desc['content']

    meta_desc['content'].strip
  end

  def favicon_url
    favicon_link = @doc.at_css('link[rel*="icon"]')
    return nil unless favicon_link && favicon_link['href']

    resolve_url(favicon_link['href'])
  end

  private

  def fetch_document
    document = nil
    SafeFetch.fetch(
      external_link,
      max_bytes: MAX_RESPONSE_BYTES,
      allowed_content_types: ALLOWED_CONTENT_TYPES,
      allowed_content_type_prefixes: []
    ) do |result|
      content = result.tempfile.read
      document = sitemap? ? Nokogiri::XML(content) : Nokogiri::HTML(content)
    end
    document
  end

  def sitemap?
    @external_link.end_with?('.xml')
  end

  def extract_links_from_sitemap
    @doc.xpath('//*[local-name()="loc"]').filter_map { |node| normalized_allowed_url(node.text) }.to_set
  end

  def extract_links_from_html
    @doc.xpath('//a/@href').filter_map { |link| normalized_allowed_url(link.value) }.to_set
  end

  def normalized_allowed_url(value)
    return if value.to_s.strip.blank? || value.to_s.strip.start_with?('#')

    absolute_url = URI.join(external_link, value.to_s).to_s
    return unless Captain::Documents::UrlPolicy.allowed_for_root?(
      absolute_url,
      @root_url,
      allow_subdomains: @allow_subdomains
    )

    Captain::Documents::UrlPolicy.normalize!(absolute_url, resolve: false)
  rescue URI::InvalidURIError, Captain::Documents::UrlPolicy::InvalidUrlError
    nil
  end

  def resolve_url(url)
    return url if url.start_with?('http')

    URI.join(@external_link, url).to_s
  rescue StandardError
    url
  end
end
