# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

class Integrations::MetaCapi::ApiClient
  GRAPH_BASE_URL = 'https://graph.facebook.com/v21.0'
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 20

  class ApiError < StandardError
    attr_reader :status, :code, :details

    def initialize(message, status: 422, code: 'META_CAPI_ERROR', details: nil)
      super(message)
      @status = status
      @code = code
      @details = details
    end
  end

  def initialize(dataset_id:, access_token:, base_url: GRAPH_BASE_URL)
    @dataset_id = dataset_id.to_s.strip
    @access_token = access_token.to_s.strip
    @base_url = base_url.to_s.chomp('/')
  end

  def send_events(events, test_event_code: nil)
    validate_credentials!
    payload = {
      data: Array(events),
      access_token: @access_token
    }
    payload[:test_event_code] = test_event_code.to_s.strip if test_event_code.present?

    post("/#{@dataset_id}/events", payload)
  end

  private

  def validate_credentials!
    raise ApiError.new('Meta Dataset / Pixel ID is required', code: 'MISSING_DATASET_ID') if @dataset_id.blank?
    raise ApiError.new('Meta Conversions API access token is required', code: 'MISSING_ACCESS_TOKEN') if @access_token.blank?
  end

  def post(path, payload)
    uri = URI.parse("#{@base_url}#{path}")
    request = Net::HTTP::Post.new(uri.request_uri)
    request['Content-Type'] = 'application/json'
    request['Accept'] = 'application/json'
    request.body = JSON.generate(payload)

    response = perform_request(uri, request)
    parsed = parse_json(response.body)
    return parsed if response.code.to_i.between?(200, 299) && parsed.is_a?(Hash)

    raise build_error(response, parsed)
  end

  def perform_request(uri, request)
    Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == 'https',
      open_timeout: OPEN_TIMEOUT,
      read_timeout: READ_TIMEOUT
    ) { |http| http.request(request) }
  rescue Timeout::Error, SocketError, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError => e
    raise ApiError.new("Meta Graph API connection error: #{e.message}", status: 503, code: 'NETWORK_ERROR')
  end

  def parse_json(raw_body)
    return {} if raw_body.blank?

    JSON.parse(raw_body)
  rescue JSON::ParserError
    { 'raw' => raw_body.to_s }
  end

  def build_error(response, parsed)
    err = parsed.is_a?(Hash) ? (parsed['error'] || {}) : {}
    msg = err['error_user_msg'].presence || err['message'].presence || "Meta CAPI HTTP #{response.code}"
    ApiError.new(msg, status: response.code.to_i, code: err['code'] || 'META_CAPI_HTTP_ERROR', details: err)
  end
end
