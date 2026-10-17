# frozen_string_literal: true

require 'cgi'
require 'json'
require 'net/http'
require 'uri'

module Telephony
  module Beeline
    class ApiClient
      DEFAULT_BASE_URL = 'https://cloudpbx.beeline.kz/apis/portal'
      DEFAULT_TIMEOUT_SECONDS = 15
      DEFAULT_SUBSCRIPTION_EXPIRES = 86_400
      DEFAULT_SUBSCRIPTION_TYPE = 'BASIC_CALL'

      class ApiError < StandardError
        attr_reader :status, :body

        def initialize(message, status: nil, body: nil)
          super(message)
          @status = status
          @body = body
        end
      end

      attr_reader :base_url, :api_token, :verify_ssl

      def self.for_channel(channel)
        new(channel: channel)
      end

      def initialize(channel: nil, base_url: nil, api_token: nil, verify_ssl: nil)
        config = channel.respond_to?(:provider_config_hash) ? channel.provider_config_hash : {}
        @base_url = normalize_base_url(
          base_url || config['beeline_api_url'] || ENV.fetch('BEELINE_API_URL', DEFAULT_BASE_URL)
        )
        @api_token = (api_token || config['beeline_api_token'] || ENV.fetch('BEELINE_API_TOKEN', nil)).to_s.strip
        @verify_ssl = if verify_ssl.nil?
                        ActiveModel::Type::Boolean.new.cast(
                          config.fetch('beeline_verify_ssl', ENV.fetch('BEELINE_VERIFY_SSL', 'true'))
                        )
                      else
                        ActiveModel::Type::Boolean.new.cast(verify_ssl)
                      end
      end

      def configured?
        @api_token.present? && @base_url.present?
      end

      def abonents
        request_json(:get, '/abonents')
      end

      def subscribe_webhook(
        url:,
        expires: DEFAULT_SUBSCRIPTION_EXPIRES,
        subscription_type: DEFAULT_SUBSCRIPTION_TYPE,
        target_id: nil,
        pattern: nil
      )
        payload = {
          url: url.to_s.strip,
          expires: expires.to_i,
          subscriptionType: subscription_type.to_s
        }
        payload[:targetId] = target_id.to_s if target_id.present?
        payload[:pattern] = pattern.to_s if pattern.present?

        request_json(:post, '/subscription', body: payload)
      end

      def renew_subscription(subscription_id:, expires: DEFAULT_SUBSCRIPTION_EXPIRES)
        raise ApiError, 'Beeline subscription_id is blank' if subscription_id.to_s.strip.blank?

        body = {
          subscriptionId: subscription_id.to_s.strip,
          expires: expires.to_i
        }
        request_json(:put, '/subscription', body: body)
      rescue ApiError => e
        raise unless [404, 405].include?(e.status)

        escaped = CGI.escape(subscription_id.to_s.strip)
        request_json(:put, "/subscription/#{escaped}", body: { expires: expires.to_i })
      end

      alias update_subscription renew_subscription

      def subscription(subscription_id)
        request_json(:get, '/subscription', params: { subscriptionId: subscription_id.to_s })
      rescue ApiError => e
        raise unless e.status == 404

        request_json(:get, "/subscription/#{CGI.escape(subscription_id.to_s)}")
      end

      alias subscription_status subscription

      def delete_subscription(subscription_id)
        request_json(:delete, "/subscription/#{CGI.escape(subscription_id.to_s)}")
      end

      def statistics(date_from: nil, date_to: nil, page: 0, page_size: 100, user_id: nil)
        params = {
          page: page.to_i,
          pageSize: [[page_size.to_i, 1].max, 100].min
        }
        params[:dateFrom] = format_timestamp_param(date_from) if date_from.present?
        params[:dateTo] = format_timestamp_param(date_to) if date_to.present?
        params[:userId] = user_id.to_s if user_id.present?

        begin
          request_json(:get, '/v2/statistics', params: params)
        rescue ApiError => e
          raise unless e.status == 404

          request_json(:get, '/statistics', params: params)
        end
      end

      def record_reference(record_id)
        escaped = CGI.escape(record_id.to_s.strip)
        request_json(:get, "/records/#{escaped}/reference")
      rescue ApiError => e
        raise unless e.status == 404

        request_json(:get, "/v2/records/#{escaped}/reference")
      end

      def download_recording(record_id)
        raise ApiError, 'Beeline record_id is blank' if record_id.to_s.strip.blank?

        escaped_id = CGI.escape(record_id.to_s.strip)
        response = begin
          perform_raw_request(:get, "/v2/records/#{escaped_id}/download")
        rescue ApiError => e
          raise unless e.status == 404

          begin
            perform_raw_request(:get, "/records/#{escaped_id}/download")
          rescue ApiError => inner_error
            raise unless inner_error.status == 404

            download_from_reference_url(record_id)
          end
        end

        content_type = response['content-type'].to_s.split(';').first.presence || 'audio/mpeg'
        disposition_name = response['content-disposition'].to_s[/filename="?([^";]+)"?/i, 1]
        ext = extension_for_content_type(content_type)
        {
          body: response.body.to_s,
          content_type: content_type,
          filename: disposition_name.presence || "beeline-#{record_id.to_s.gsub(/[^a-zA-Z0-9_-]/, '_')}.#{ext}"
        }
      end

      private

      def download_from_reference_url(record_id)
        ref = record_reference(record_id)
        ref_url = ref.is_a?(Hash) ? (ref['url'] || ref['downloadUrl'] || ref['reference']) : nil
        raise ApiError.new('Beeline record reference URL not found', status: 404) if ref_url.to_s.strip.blank?

        uri = URI.parse(ref_url.to_s.strip)
        request = Net::HTTP::Get.new(uri)
        request['X-MPBX-API-AUTH-TOKEN'] = @api_token if uri.host == URI.parse(@base_url).host
        response = execute_http(uri, request)
        unless response.is_a?(Net::HTTPSuccess)
          raise ApiError.new(
            "Beeline recording reference GET failed with HTTP #{response.code}",
            status: response.code.to_i,
            body: response.body.to_s
          )
        end

        response
      end

      def normalize_base_url(raw_url)
        cleaned = raw_url.to_s.strip.sub(%r{/+\z}, '')
        cleaned.presence || DEFAULT_BASE_URL
      end

      def format_timestamp_param(value)
        case value
        when Time, DateTime, ActiveSupport::TimeWithZone
          value.utc.iso8601
        else
          value.to_s
        end
      end

      def extension_for_content_type(content_type)
        case content_type.to_s.downcase
        when /wav/
          'wav'
        when /ogg/
          'ogg'
        else
          'mp3'
        end
      end

      def request_json(method, path, params: {}, body: nil)
        response = perform_raw_request(method, path, params: params, body: body)
        raw_body = response.body.to_s.strip
        return {} if raw_body.blank?

        JSON.parse(raw_body)
      rescue JSON::ParserError
        { 'raw' => response.body.to_s }
      end

      def perform_raw_request(method, path, params: {}, body: nil)
        raise ApiError, 'Beeline API client is not configured' unless configured?

        uri = build_uri(path, params)
        request = build_http_request(method, uri, body: body)
        response = execute_http(uri, request)

        unless response.is_a?(Net::HTTPSuccess)
          raise ApiError.new(
            "Beeline API #{method.to_s.upcase} #{path} failed with HTTP #{response.code}",
            status: response.code.to_i,
            body: response.body.to_s
          )
        end

        response
      end

      def build_uri(path, params = {})
        normalized_path = path.to_s.start_with?('/') ? path.to_s : "/#{path}"
        uri = URI.parse("#{@base_url}#{normalized_path}")
        compact_params = params.compact.transform_values(&:to_s).reject { |_, v| v.blank? }
        if compact_params.any?
          existing = URI.decode_www_form(uri.query.to_s)
          uri.query = URI.encode_www_form(existing + compact_params.to_a)
        end
        uri
      end

      def build_http_request(method, uri, body: nil)
        klass = case method.to_sym
                when :get then Net::HTTP::Get
                when :post then Net::HTTP::Post
                when :put then Net::HTTP::Put
                when :delete then Net::HTTP::Delete
                else raise ArgumentError, "Unsupported HTTP method: #{method}"
                end

        request = klass.new(uri)
        request['Accept'] = 'application/json'
        request['X-MPBX-API-AUTH-TOKEN'] = @api_token
        if body.present?
          request['Content-Type'] = 'application/json'
          request.body = body.is_a?(String) ? body : JSON.generate(body)
        end
        request
      end

      def execute_http(uri, request)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        http.verify_mode = @verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
        http.open_timeout = DEFAULT_TIMEOUT_SECONDS
        http.read_timeout = DEFAULT_TIMEOUT_SECONDS
        http.request(request)
      end
    end
  end
end
