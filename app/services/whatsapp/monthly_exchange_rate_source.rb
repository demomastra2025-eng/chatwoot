require 'bigdecimal'
require 'date'
require 'net/http'
require 'nokogiri'
require 'openssl'
require 'uri'

class Whatsapp::MonthlyExchangeRateSource
  SOURCE_HOST = 'nationalbank.kz'.freeze
  SOURCE_PATH = '/rss/get_rates.cfm'.freeze
  SOURCE_BASE_URL = "https://#{SOURCE_HOST}#{SOURCE_PATH}".freeze
  OPEN_TIMEOUT = 3
  READ_TIMEOUT = 5
  WRITE_TIMEOUT = 3
  MAX_RESPONSE_BYTES = 1_048_576

  class RateUnavailable < StandardError
    attr_reader :error_code

    def initialize(error_code)
      @error_code = error_code
      super(error_code)
    end
  end

  def initialize(requested_date:)
    @requested_date = requested_date
  end

  def fetch
    uri = source_uri
    response, body = make_request(uri)
    raise RateUnavailable, "http_#{response.code}" unless response.is_a?(Net::HTTPSuccess)

    parse_rate_response(body)
  rescue Timeout::Error, SocketError, OpenSSL::SSL::SSLError, IOError, SystemCallError,
         Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError
    raise RateUnavailable, 'transport_error'
  end

  def source_url
    source_uri.to_s
  end

  private

  def source_uri
    uri = URI(SOURCE_BASE_URL)
    uri.query = URI.encode_www_form(fdate: @requested_date.strftime('%d.%m.%Y'))
    return uri if uri.is_a?(URI::HTTPS) && uri.host == SOURCE_HOST && uri.path == SOURCE_PATH && uri.port == 443

    raise RateUnavailable, 'source_not_allowed'
  end

  def make_request(uri)
    http = build_http_client(uri)
    response = nil
    body = nil
    http.start do |connection|
      response = connection.request(build_http_request(uri)) do |http_response|
        body = read_bounded_body(http_response)
      end
    end
    [response, body || ''.b]
  end

  def build_http_client(uri)
    Net::HTTP.new(uri.host, uri.port, nil).tap do |http|
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.write_timeout = WRITE_TIMEOUT
      http.max_retries = 0
    end
  end

  def build_http_request(uri)
    Net::HTTP::Get.new(uri).tap do |request|
      request['Accept'] = 'application/xml, text/xml'
    end
  end

  def read_bounded_body(response)
    body = ''.b
    response.read_body do |chunk|
      raise RateUnavailable, 'invalid_response_size' if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES

      body << chunk.b
    end
    body
  end

  def parse_rate_response(body)
    document = parse_xml(body)
    item = usd_item(document)
    nominal_rate = decimal_value(item.at_xpath('./*[local-name()="description"]')&.text)
    nominal_units = integer_value(item.at_xpath('./*[local-name()="quant"]')&.text)
    validate_nominal_values!(nominal_rate, nominal_units)

    {
      effective_date: effective_date_from(document),
      nominal_rate: nominal_rate,
      nominal_units: nominal_units,
      rate_per_usd: nominal_rate / nominal_units
    }
  end

  def parse_xml(body)
    validate_response_body!(body)
    Nokogiri::XML::Document.parse(
      body,
      nil,
      nil,
      Nokogiri::XML::ParseOptions::STRICT | Nokogiri::XML::ParseOptions::NONET
    )
  rescue Nokogiri::XML::SyntaxError
    raise RateUnavailable, 'invalid_xml'
  end

  def validate_response_body!(body)
    raise RateUnavailable, 'invalid_response_size' unless body.is_a?(String) && body.bytesize <= MAX_RESPONSE_BYTES
    raise RateUnavailable, 'xml_dtd_not_allowed' if body.b.match?(/<!\s*(?:DOCTYPE|ENTITY)\b/i)
  end

  def usd_item(document)
    items = document.xpath('//*[local-name()="item"]').select { |item| usd_item?(item) }
    raise RateUnavailable, 'usd_rate_missing' unless items.one?

    items.first
  end

  def usd_item?(item)
    currency_code(item) == 'USD'
  end

  def currency_code(item)
    title_code = iso_currency_code(item.at_xpath('./*[local-name()="title"]')&.text)
    code_value = iso_currency_code(item.at_xpath('./*[local-name()="code"]')&.text)
    raise RateUnavailable, 'currency_code_conflict' if title_code.present? && code_value.present? && title_code != code_value

    title_code || code_value
  end

  def iso_currency_code(value)
    code = value.to_s.strip.upcase
    code if code.match?(/\A[A-Z]{3}\z/)
  end

  def decimal_value(value)
    return if value.blank?

    BigDecimal(value.strip, exception: false)
  end

  def integer_value(value)
    return if value.blank?

    Integer(value.strip, 10, exception: false)
  end

  def validate_nominal_values!(nominal_rate, nominal_units)
    return if nominal_rate&.positive? && nominal_units&.positive?

    raise RateUnavailable, 'usd_rate_invalid'
  end

  def effective_date_from(document)
    raw_date = source_date_value(document)
    raise RateUnavailable, 'effective_date_missing' if raw_date.blank?

    date = parse_source_date(raw_date)
    raise RateUnavailable, 'future_effective_date' if date > @requested_date

    date
  rescue Date::Error
    raise RateUnavailable, 'invalid_effective_date'
  end

  def source_date_value(document)
    root = document.root
    root&.[]('date') || root&.[]('effective_date') || root&.[]('effectiveDate') ||
      root&.at_xpath('./*[local-name()="date" or local-name()="effective_date" or local-name()="effectiveDate"]')&.text
  end

  def parse_source_date(raw_date)
    value = raw_date.strip
    return Date.iso8601(value) if value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.strptime(value, '%d.%m.%Y')
  end
end
