require 'uri'

module Content::Postiz
  class Client
    DEFAULT_BASE_URL = 'http://127.0.0.1:4007/api/public/v1'.freeze
    CONNECT_TIMEOUT = 3
    READ_TIMEOUT = 15

    attr_reader :api_key, :base_url

    def initialize(api_key:, base_url: nil)
      @api_key = api_key.to_s.strip
      @base_url = normalize_base_url(base_url.presence || configured_base_url)
      raise Error.new(code: 'POSTIZ_UNAUTHORIZED', message: 'Postiz API key is missing', status: :unauthorized) if @api_key.blank?
    end

    def test_connection
      list_integrations
      { connected: true }
    rescue Error => e
      { connected: false, error: error_payload(e) }
    end

    def list_integrations
      request(:get, '/integrations')
    end

    def oauth_url(provider, refresh: nil)
      query = {}
      query[:refresh] = refresh if refresh.present?
      request(:get, "/social/#{escape_path(provider)}", query: query)
    end

    def delete_integration(id)
      request(:delete, "/integrations/#{escape_path(id)}")
    end

    def find_slot(integration_id)
      request(:get, "/find-slot/#{escape_path(integration_id)}")
    end

    def list_posts(start_date:, end_date:, customer: nil)
      query = { startDate: start_date, endDate: end_date }
      query[:customer] = customer if customer.present?
      request(:get, '/posts', query: query)
    end

    def create_post(payload)
      request(:post, '/posts', body: payload)
    end

    def delete_post(id)
      request(:delete, "/posts/#{escape_path(id)}")
    end

    def change_post_status(id, status)
      request(:put, "/posts/#{escape_path(id)}/status", body: { status: status })
    end

    def missing_post(id)
      request(:get, "/posts/#{escape_path(id)}/missing")
    end

    def upload(file)
      request(:post, '/upload', body: { file: file }, multipart: true)
    end

    def upload_from_url(url)
      request(:post, '/upload-from-url', body: { url: url })
    end

    def analytics(integration:, date: nil)
      query = {}
      query[:date] = date if date.present?
      request(:get, "/analytics/#{escape_path(integration)}", query: query)
    end

    def post_analytics(post_id:, date: nil)
      query = {}
      query[:date] = date if date.present?
      request(:get, "/analytics/post/#{escape_path(post_id)}", query: query)
    end

    private

    def request(method, path, query: nil, body: nil, multipart: false)
      response = HTTParty.public_send(
        method,
        url_for(path),
        request_options(query: query, body: body, multipart: multipart)
      )
      parse_response(response)
    rescue SocketError, Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout, HTTParty::Error => e
      raise Error.new(code: 'POSTIZ_UNAVAILABLE', message: 'Postiz is unavailable', status: :bad_gateway, details: e.message)
    end

    def request_options(query:, body:, multipart:)
      options = {
        headers: headers,
        timeout: READ_TIMEOUT,
        open_timeout: CONNECT_TIMEOUT
      }
      options[:query] = query.compact if query.present?
      if body.present?
        if multipart
          options[:body] = body
          options[:multipart] = true
        else
          options[:headers] = headers.merge('Content-Type' => 'application/json')
          options[:body] = body.to_json
        end
      end
      options
    end

    def parse_response(response)
      parsed_body = parse_body(response.body)
      return parsed_body if response.success? && json_response?(response)
      return {} if response.success? && response.body.blank?

      raise Error.new(
        code: error_code_for(response.code),
        message: error_message_for(parsed_body, response),
        status: status_for(response.code),
        details: parsed_body
      )
    end

    def parse_body(body)
      return {} if body.blank?

      JSON.parse(body)
    rescue JSON::ParserError
      body
    end

    def error_code_for(http_code)
      case http_code.to_i
      when 200..299 then 'POSTIZ_INVALID_RESPONSE'
      when 401, 403 then 'POSTIZ_UNAUTHORIZED'
      when 400, 422 then 'POSTIZ_VALIDATION_ERROR'
      when 429 then 'POSTIZ_RATE_LIMITED'
      else 'POSTIZ_UPSTREAM_ERROR'
      end
    end

    def status_for(http_code)
      case http_code.to_i
      when 200..299 then :ok
      when 401, 403 then :unauthorized
      when 400, 422 then :unprocessable_content
      when 429 then :too_many_requests
      else :bad_gateway
      end
    end

    def error_message_for(parsed_body, response)
      return 'Postiz returned a non-JSON response' if response.success? && !json_response?(response)

      if parsed_body.is_a?(Hash)
        parsed_body['msg'].presence || parsed_body['message'].presence || parsed_body['error'].presence || "Postiz returned HTTP #{response.code}"
      else
        parsed_body.presence || "Postiz returned HTTP #{response.code}"
      end
    end

    def error_payload(error)
      payload = { code: error.code, message: error.message }
      payload[:details] = error.details if error.details.present?
      payload
    end

    def json_response?(response)
      response.headers['content-type'].to_s.include?('application/json')
    end

    def headers
      {
        'Accept' => 'application/json',
        'Authorization' => api_key
      }
    end

    def url_for(path)
      "#{base_url}#{path}"
    end

    def escape_path(value)
      URI.encode_www_form_component(value.to_s)
    end

    def configured_base_url
      ENV.fetch('POSTIZ_BASE_URL', DEFAULT_BASE_URL)
    end

    def normalize_base_url(value)
      uri = URI.parse(value.to_s)
      raise URI::InvalidURIError if uri.scheme.blank? || uri.host.blank?

      normalized = uri.to_s.chomp('/')
      return normalized if normalized.end_with?('/api/public/v1')
      return normalized.sub(%r{/public/v1\z}, '/api/public/v1') if normalized.end_with?('/public/v1')

      "#{normalized}/api/public/v1"
    rescue URI::InvalidURIError
      raise Error.new(code: 'POSTIZ_INVALID_BASE_URL', message: 'Postiz base URL is invalid', status: :unprocessable_content)
    end
  end
end
