class SafeFetch::Fetcher
  NET_HTTP_REQUESTS = {
    get: Net::HTTP::Get,
    post: Net::HTTP::Post,
    put: Net::HTTP::Put,
    patch: Net::HTTP::Patch,
    delete: Net::HTTP::Delete,
    head: Net::HTTP::Head
  }.freeze

  def initialize(options)
    @options = options
  end

  def fetch(&)
    with_tempfile do |tempfile|
      response = stream_response(tempfile)
      return fetch_redirect(response, tempfile, &) if response.is_a?(Net::HTTPRedirection)

      raise SafeFetch::HttpError, "#{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

      tempfile.rewind
      yield SafeFetch::Result.new(
        tempfile: tempfile,
        filename: options.filename,
        content_type: normalized_content_type(response['content-type'])
      )
    end
  end

  private

  attr_reader :options

  def with_tempfile
    tempfile = Tempfile.new('onelink-safe-fetch', binmode: true)
    yield tempfile
  ensure
    tempfile&.close!
  end

  def stream_response(tempfile)
    response = nil
    bytes_written = 0

    with_http_client(options.uri) do |http|
      request = build_request(options.uri)
      http.request(request) do |res|
        response = res
        next if res.is_a?(Net::HTTPRedirection)
        next unless res.is_a?(Net::HTTPSuccess)

        validate_content_type!(res['content-type'])
        bytes_written = write_response_body(res, tempfile, bytes_written)
      end
    end

    response
  end

  def fetch_redirect(response, tempfile, &)
    tempfile.rewind
    tempfile.truncate(0)
    self.class.new(options.redirect(response['location'])).fetch(&)
  end

  def with_http_client(uri, &)
    http = Net::HTTP.new(uri.host, uri.port)
    http.ipaddr = SafeFetch.resolve_public_ip!(uri.host, allow_private_network: options.private_network_allowed?)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = options.open_timeout
    http.read_timeout = options.read_timeout
    http.max_retries = 0 if http.respond_to?(:max_retries=)

    http.start(&)
  end

  def build_request(uri)
    request_class = NET_HTTP_REQUESTS.fetch(options.method)
    request = request_class.new(uri.request_uri)
    options.headers.each { |key, value| request[key] = value.to_s }
    request.body = options.body if options.body.present? && request.request_body_permitted?
    request.basic_auth(*options.http_basic_authentication) if options.http_basic_authentication.present?
    request
  end

  def validate_content_type!(content_type)
    return unless options.validate_content_type?
    return if allowed_content_type?(content_type)

    raise SafeFetch::UnsupportedContentTypeError, "content-type not allowed: #{content_type}"
  end

  def write_response_body(response, tempfile, bytes_written)
    response.read_body do |chunk|
      bytes_written += chunk.bytesize
      raise SafeFetch::FileTooLargeError, "exceeded #{options.effective_max_bytes} bytes" if bytes_written > options.effective_max_bytes

      tempfile.write(chunk)
    end

    bytes_written
  end

  def allowed_content_type?(value)
    mime = normalized_content_type(value)
    return false if mime.blank?

    options.allowed_content_type_prefixes.any? { |prefix| mime.start_with?(prefix) } ||
      options.allowed_content_types.include?(mime)
  end

  def normalized_content_type(value)
    value.to_s.split(';').first&.strip&.downcase
  end
end
