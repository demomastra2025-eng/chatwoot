class SafeFetch::RequestOptions
  SUPPORTED_METHODS = %i[get post put patch delete head].freeze

  DEFAULTS = {
    method: :get,
    body: nil,
    max_bytes: nil,
    open_timeout: SafeFetch::DEFAULT_OPEN_TIMEOUT,
    read_timeout: SafeFetch::DEFAULT_READ_TIMEOUT,
    headers: nil,
    http_basic_authentication: nil,
    allowed_content_type_prefixes: SafeFetch::DEFAULT_ALLOWED_CONTENT_TYPE_PREFIXES,
    allowed_content_types: SafeFetch::DEFAULT_ALLOWED_CONTENT_TYPES,
    validate_content_type: true,
    private_network_allowed_hosts: nil,
    redirects_remaining: SafeFetch::DEFAULT_MAX_REDIRECTS
  }.freeze

  attr_reader :allowed_content_type_prefixes, :allowed_content_types, :body, :headers,
              :http_basic_authentication, :method, :open_timeout, :read_timeout,
              :private_network_allowed_hosts, :redirects_remaining, :uri, :url

  def initialize(url:, **options)
    config = DEFAULTS.merge(options)
    @url = url
    @uri = parse_and_validate_url!(url)
    @method = normalize_method(config[:method])
    @body = config[:body]
    @max_bytes = config[:max_bytes]
    @open_timeout = config[:open_timeout]
    @read_timeout = config[:read_timeout]
    @headers = normalize_headers(config[:headers])
    @http_basic_authentication = config[:http_basic_authentication]
    @allowed_content_type_prefixes = Array(config[:allowed_content_type_prefixes])
    @allowed_content_types = Array(config[:allowed_content_types])
    @validate_content_type = config[:validate_content_type]
    @private_network_allowed_hosts = normalize_private_network_allowed_hosts(config[:private_network_allowed_hosts])
    @redirects_remaining = config[:redirects_remaining]
  end

  def effective_max_bytes
    @effective_max_bytes ||= @max_bytes || SafeFetch.default_max_bytes
  end

  def filename
    @filename ||= File.basename(uri.path).presence || "download-#{Time.current.to_i}-#{SecureRandom.hex(4)}"
  end

  def redirect(location)
    raise SafeFetch::FetchError, 'too many redirects' if redirects_remaining <= 0
    raise SafeFetch::InvalidUrlError, 'missing redirect location' if location.blank?

    redirected_uri = URI.join(uri.to_s, location)
    self.class.new(
      url: redirected_uri.to_s,
      method: method,
      body: body,
      max_bytes: effective_max_bytes,
      open_timeout: open_timeout,
      read_timeout: read_timeout,
      headers: headers_for_redirect(redirected_uri),
      http_basic_authentication: basic_authentication_for_redirect(redirected_uri),
      allowed_content_type_prefixes: allowed_content_type_prefixes,
      allowed_content_types: allowed_content_types,
      validate_content_type: validate_content_type?,
      private_network_allowed_hosts: private_network_allowed_hosts,
      redirects_remaining: redirects_remaining - 1
    )
  end

  def validate_content_type?
    @validate_content_type
  end

  def private_network_allowed?
    private_network_allowed_hosts.include?(uri.hostname.to_s.downcase)
  end

  private

  def parse_and_validate_url!(value)
    parsed_uri = URI.parse(value)
    raise SafeFetch::InvalidUrlError, 'scheme must be http or https' unless parsed_uri.is_a?(URI::HTTP) || parsed_uri.is_a?(URI::HTTPS)
    raise SafeFetch::InvalidUrlError, 'missing host' if parsed_uri.host.blank?

    parsed_uri
  end

  def normalize_method(value)
    http_method = value.to_s.downcase.to_sym
    return http_method if SUPPORTED_METHODS.include?(http_method)

    raise SafeFetch::UnsupportedMethodError, "unsupported method: #{value}"
  end

  def normalize_headers(value)
    value.to_h.transform_keys(&:to_s)
  end

  def normalize_private_network_allowed_hosts(value)
    Array(value).flat_map { |entry| entry.to_s.split(',') }
                .map { |entry| entry.strip.downcase }
                .compact_blank
                .uniq
  end

  def headers_for_redirect(redirected_uri)
    return headers if same_origin?(redirected_uri, uri)

    headers.reject { |key, _value| SafeFetch::DEFAULT_SENSITIVE_HEADERS.include?(key.to_s.downcase) }
  end

  def basic_authentication_for_redirect(redirected_uri)
    return http_basic_authentication if same_origin?(redirected_uri, uri)

    nil
  end

  def same_origin?(request_uri, other_uri)
    request_uri.scheme == other_uri.scheme && request_uri.hostname == other_uri.hostname && request_uri.port == other_uri.port
  end
end
