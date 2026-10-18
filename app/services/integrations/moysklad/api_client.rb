require 'net/http'
require 'uri'
require 'json'
require 'zlib'
require 'stringio'
require 'base64'

class Integrations::Moysklad::ApiClient
  BASE_URL = 'https://api.moysklad.ru/api/remap/1.2'.freeze
  PAGE_LIMIT = 100
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 30

  class ApiError < StandardError
    attr_reader :status, :code, :details

    def initialize(message, status: 422, code: 'MOYSKLAD_API_ERROR', details: nil)
      super(message)
      @status = status
      @code = code
      @details = details
    end
  end

  def initialize(access_token: nil, base_url: BASE_URL)
    @access_token = access_token.to_s.strip
    @base_url = base_url.chomp('/')
  end

  def self.exchange_credentials_for_token!(login:, password:, base_url: BASE_URL)
    uri = URI.parse("#{base_url.chomp('/')}/security/token")
    request = Net::HTTP::Post.new(uri.request_uri)
    encoded_auth = Base64.strict_encode64("#{login.to_s.strip}:#{password}")
    request['Authorization'] = "Basic #{encoded_auth}"
    request['Accept'] = 'application/json;charset=utf-8'
    request['Accept-Encoding'] = 'gzip'

    response = perform_http_request(uri, request)
    body = parse_response_body(response)

    unless response.code.to_i.between?(200, 299) && body.is_a?(Hash) && body['access_token'].present?
      raise build_api_error(response, body, default_message: 'Не удалось получить токен МойСклад по логину и паролю')
    end

    body['access_token']
  end

  def fetch_stores
    data = get('/entity/store', limit: PAGE_LIMIT)
    Array(data['rows'])
  end

  def fetch_stock_by_store
    data = get('/report/stock/bystore/current')
    Array(data)
  rescue ApiError
    []
  end

  def fetch_assortment_page(limit: PAGE_LIMIT, offset: 0, filter: nil)
    safe_limit = limit.to_i.clamp(1, PAGE_LIMIT)
    params = {
      limit: safe_limit,
      offset: [offset.to_i, 0].max,
      expand: 'productFolder,uom,components'
    }
    params[:filter] = filter if filter.present?
    get('/entity/assortment', params)
  end

  def fetch_all_assortment(max_pages: 50)
    rows = []
    offset = 0
    pages = 0

    loop do
      page = fetch_assortment_page(limit: PAGE_LIMIT, offset: offset)
      batch = Array(page['rows'])
      rows.concat(batch)

      total_size = page.dig('meta', 'size').to_i
      offset += batch.size
      pages += 1

      break if batch.empty? || offset >= total_size || pages >= max_pages
    end

    rows
  end

  def get(path, params = {})
    raise ApiError.new('API-токен МойСклад не указан', status: 401, code: 'MOYSKLAD_TOKEN_MISSING') if @access_token.blank?

    uri = build_uri(path, params)
    request = Net::HTTP::Get.new(uri.request_uri)
    request['Authorization'] = "Bearer #{@access_token}"
    request['Accept'] = 'application/json;charset=utf-8'
    request['Content-Type'] = 'application/json'
    request['Accept-Encoding'] = 'gzip'

    response = self.class.perform_http_request(uri, request)
    body = self.class.parse_response_body(response)
    raise self.class.build_api_error(response, body) unless response.code.to_i.between?(200, 299)

    body
  end

  def self.perform_http_request(uri, request)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT
    http.request(request)
  rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET, OpenSSL::SSL::SSLError => e
    raise ApiError.new("Ошибка соединения с МойСклад: #{e.message}", status: 502, code: 'MOYSKLAD_NETWORK_ERROR')
  end

  def self.parse_response_body(response)
    raw = response.body.to_s
    return {} if raw.empty?

    raw = Zlib::GzipReader.new(StringIO.new(raw)).read if raw.b.start_with?("\x1F\x8B".b)
    JSON.parse(raw.force_encoding('UTF-8'))
  rescue Zlib::GzipFile::Error, JSON::ParserError
    {}
  end

  def self.build_api_error(response, body, default_message: 'Ошибка запроса к API МойСклад')
    errors = body.is_a?(Hash) ? Array(body['errors']) : []
    first_error = errors.first.is_a?(Hash) ? errors.first : {}
    message = first_error['error'].presence || default_message
    ms_code = first_error['code']

    ApiError.new(
      message,
      status: response.code.to_i.nonzero? || 422,
      code: ms_code ? "MOYSKLAD_#{ms_code}" : 'MOYSKLAD_API_ERROR',
      details: errors.presence
    )
  end

  private

  def build_uri(path, params)
    clean_path = path.start_with?('/') ? path : "/#{path}"
    uri = URI.parse("#{@base_url}#{clean_path}")
    uri.query = URI.encode_www_form(params.compact) if params.present?
    uri
  end
end
