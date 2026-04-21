require 'ipaddr'
require 'net/http'
require 'openssl'
require 'resolv'
require 'securerandom'
require 'tempfile'

module SafeFetch
  DEFAULT_ALLOWED_CONTENT_TYPE_PREFIXES = %w[image/ video/].freeze
  DEFAULT_MAX_BYTES_FALLBACK_MB = 40
  DEFAULT_OPEN_TIMEOUT = 2
  DEFAULT_READ_TIMEOUT = 20
  DEFAULT_MAX_REDIRECTS = 3

  UNSAFE_IP_RANGES = [
    IPAddr.new('0.0.0.0/8'),
    IPAddr.new('10.0.0.0/8'),
    IPAddr.new('100.64.0.0/10'),
    IPAddr.new('127.0.0.0/8'),
    IPAddr.new('169.254.0.0/16'),
    IPAddr.new('172.16.0.0/12'),
    IPAddr.new('192.168.0.0/16'),
    IPAddr.new('198.18.0.0/15'),
    IPAddr.new('224.0.0.0/4'),
    IPAddr.new('240.0.0.0/4'),
    IPAddr.new('::/128'),
    IPAddr.new('::1/128'),
    IPAddr.new('fc00::/7'),
    IPAddr.new('fe80::/10'),
    IPAddr.new('ff00::/8')
  ].freeze

  Result = Data.define(:tempfile, :filename, :content_type)

  class Error < StandardError; end
  class InvalidUrlError < Error; end
  class UnsafeUrlError < Error; end
  class FetchError < Error; end
  class HttpError < Error; end
  class FileTooLargeError < Error; end
  class UnsupportedContentTypeError < Error; end

  def self.fetch(url,
                 max_bytes: nil,
                 allowed_content_type_prefixes: DEFAULT_ALLOWED_CONTENT_TYPE_PREFIXES)
    raise ArgumentError, 'block required' unless block_given?

    effective_max_bytes = max_bytes || default_max_bytes
    uri = parse_and_validate_url!(url)
    tempfile = Tempfile.new('onelink-safe-fetch', binmode: true)
    result = fetch_from_uri(
      uri,
      tempfile,
      max_bytes: effective_max_bytes,
      allowed_content_type_prefixes: allowed_content_type_prefixes,
      redirects_remaining: DEFAULT_MAX_REDIRECTS
    )

    tempfile.rewind
    yield Result.new(tempfile: tempfile, filename: result[:filename], content_type: result[:content_type])
  rescue URI::InvalidURIError => e
    raise InvalidUrlError, e.message
  ensure
    tempfile&.close!
  end

  class << self
    private

    def fetch_from_uri(uri, tempfile, max_bytes:, allowed_content_type_prefixes:, redirects_remaining:)
      response_payload = nil

      with_http_client(uri) do |http|
        request = Net::HTTP::Get.new(uri.request_uri)
        request['User-Agent'] = 'Onelink SafeFetch'

        http.request(request) do |response|
          response_payload = build_response_payload(
            response,
            uri,
            tempfile,
            max_bytes: max_bytes,
            allowed_content_type_prefixes: allowed_content_type_prefixes,
            redirects_remaining: redirects_remaining
          )
        end
      end

      response_payload
    end

    def build_response_payload(response, uri, tempfile, max_bytes:, allowed_content_type_prefixes:, redirects_remaining:)
      case response
      when Net::HTTPSuccess
        content_type = normalized_content_type(response['content-type'])
        unless allowed_content_type?(content_type, allowed_content_type_prefixes)
          raise UnsupportedContentTypeError, "content-type not allowed: #{response['content-type']}"
        end

        tempfile.rewind
        tempfile.truncate(0)
        stream_to_tempfile(response, tempfile, max_bytes)
        { filename: filename_for(uri), content_type: content_type }
      when Net::HTTPRedirection
        raise FetchError, 'too many redirects' if redirects_remaining <= 0

        location = response['location']
        raise InvalidUrlError, 'missing redirect location' if location.blank?

        redirected_uri = URI.join(uri.to_s, location)
        fetch_from_uri(
          redirected_uri,
          tempfile,
          max_bytes: max_bytes,
          allowed_content_type_prefixes: allowed_content_type_prefixes,
          redirects_remaining: redirects_remaining - 1
        )
      else
        raise HttpError, "#{response.code} #{response.message}"
      end
    end

    def with_http_client(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.ipaddr = resolve_public_ip!(uri.host)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = DEFAULT_OPEN_TIMEOUT
      http.read_timeout = DEFAULT_READ_TIMEOUT
      http.max_retries = 0 if http.respond_to?(:max_retries=)

      http.start do |client|
        yield client
      end
    rescue Resolv::ResolvError => e
      raise FetchError, e.message
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, IOError, EOFError,
           Errno::ECONNRESET, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError => e
      raise FetchError, e.message
    end

    def stream_to_tempfile(response, tempfile, max_bytes)
      bytes_written = 0

      response.read_body do |chunk|
        bytes_written += chunk.bytesize
        raise FileTooLargeError, "exceeded #{max_bytes} bytes" if bytes_written > max_bytes

        tempfile.write(chunk)
      end
    end

    def resolve_public_ip!(host)
      raise InvalidUrlError, 'missing host' if host.blank?
      raise UnsafeUrlError, 'localhost is not allowed' if host.casecmp('localhost').zero?

      begin
        ip = IPAddr.new(host)
        raise UnsafeUrlError, 'IP address is not allowed' if unsafe_ip?(ip.to_s)

        return ip.to_s
      rescue IPAddr::InvalidAddressError
        nil
      end

      addresses = Resolv.getaddresses(host)
      raise FetchError, 'host could not be resolved' if addresses.blank?
      raise UnsafeUrlError, 'resolved to a non-public address' if addresses.any? { |address| unsafe_ip?(address) }

      addresses.first
    end

    def parse_and_validate_url!(url)
      uri = URI.parse(url)
      raise InvalidUrlError, 'scheme must be http or https' unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
      raise InvalidUrlError, 'missing host' if uri.host.blank?

      uri
    end

    def unsafe_ip?(value)
      ip = IPAddr.new(value)
      UNSAFE_IP_RANGES.any? { |range| range.include?(ip) }
    end

    def filename_for(uri)
      File.basename(uri.path).presence || "download-#{Time.current.to_i}-#{SecureRandom.hex(4)}"
    end

    def default_max_bytes
      limit_mb = GlobalConfigService.load('MAXIMUM_FILE_UPLOAD_SIZE', DEFAULT_MAX_BYTES_FALLBACK_MB).to_i
      limit_mb = DEFAULT_MAX_BYTES_FALLBACK_MB if limit_mb <= 0
      limit_mb.megabytes
    end

    def normalized_content_type(value)
      value.to_s.split(';').first&.strip&.downcase
    end

    def allowed_content_type?(value, prefixes)
      return false if value.blank?

      prefixes.any? { |prefix| value.start_with?(prefix) }
    end
  end
end
