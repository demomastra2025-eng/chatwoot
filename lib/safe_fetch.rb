require 'ipaddr'
require 'net/http'
require 'openssl'
require 'resolv'
require 'securerandom'
require 'tempfile'

module SafeFetch
  DEFAULT_ALLOWED_CONTENT_TYPE_PREFIXES = %w[image/ video/].freeze
  DEFAULT_ALLOWED_CONTENT_TYPES = [].freeze
  DEFAULT_SENSITIVE_HEADERS = %w[authorization cookie proxy-authorization].freeze
  DEFAULT_OPEN_TIMEOUT = 2
  DEFAULT_READ_TIMEOUT = 20
  DEFAULT_MAX_BYTES_FALLBACK_MB = 40
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

  Result = Data.define(:tempfile, :filename, :content_type) do
    def original_filename
      filename
    end
  end

  class Error < StandardError; end
  class InvalidUrlError < Error; end
  class UnsafeUrlError < Error; end
  class FetchError < Error; end
  class HttpError < Error; end
  class FileTooLargeError < Error; end
  class UnsupportedContentTypeError < Error; end
  class UnsupportedMethodError < Error; end

  def self.fetch(url, **, &)
    raise ArgumentError, 'block required' unless block_given?

    SafeFetch::Fetcher.new(SafeFetch::RequestOptions.new(url: url, **)).fetch(&)
  rescue URI::InvalidURIError => e
    raise InvalidUrlError, e.message
  rescue Resolv::ResolvError, Net::OpenTimeout, Net::ReadTimeout, SocketError, IOError,
         Errno::ECONNRESET, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError => e
    raise FetchError, e.message
  end

  def self.default_max_bytes
    limit_mb = GlobalConfigService.load('MAXIMUM_FILE_UPLOAD_SIZE', DEFAULT_MAX_BYTES_FALLBACK_MB).to_i
    limit_mb = DEFAULT_MAX_BYTES_FALLBACK_MB if limit_mb <= 0
    limit_mb.megabytes
  end

  def self.resolve_public_ip!(host)
    raise InvalidUrlError, 'missing host' if host.blank?
    raise UnsafeUrlError, 'localhost is not allowed' if host.casecmp('localhost').zero?

    literal_ip = public_literal_ip(host)
    return literal_ip if literal_ip

    addresses = Resolv.getaddresses(host)
    raise FetchError, 'host could not be resolved' if addresses.blank?
    raise UnsafeUrlError, 'resolved to a non-public address' if addresses.any? { |address| unsafe_ip?(address) }

    addresses.first
  end

  def self.public_literal_ip(host)
    ip = IPAddr.new(host)
    raise UnsafeUrlError, 'IP address is not allowed' if unsafe_ip?(ip.to_s)

    ip.to_s
  rescue IPAddr::InvalidAddressError
    nil
  end

  def self.unsafe_ip?(value)
    ip = IPAddr.new(value)
    UNSAFE_IP_RANGES.any? { |range| range.include?(ip) }
  end
end

require_relative 'safe_fetch/request_options'
require_relative 'safe_fetch/fetcher'
