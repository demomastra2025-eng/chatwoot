# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'openssl'
require 'digest'

module Telephony
  module Binotel
    class ApiClient
      DEFAULT_REST_BASE_URL = 'https://api.binotel.com/api/4.0'
      DEFAULT_CABINET_BASE_URL = 'https://my.binotel.kz'
      DEFAULT_TIMEOUT_SECONDS = 15
      CABINET_COOKIE_CACHE_TTL = 25.minutes

      class ApiError < StandardError
        attr_reader :status, :body, :code

        def initialize(message, status: nil, body: nil, code: nil)
          super(message)
          @status = status
          @body = body
          @code = code
        end
      end

      attr_reader :api_key, :api_secret, :base_url

      def self.for_channel(channel)
        config = channel.respond_to?(:provider_config_hash) ? channel.provider_config_hash : {}
        new(
          api_key: config['binotel_api_key'],
          api_secret: config['binotel_api_secret'],
          base_url: config['binotel_api_url']
        )
      end

      def initialize(api_key: nil, api_secret: nil, base_url: nil, verify_ssl: true)
        @api_key = (api_key || ENV.fetch('BINOTEL_API_KEY', nil)).to_s.strip
        @api_secret = (api_secret || ENV.fetch('BINOTEL_API_SECRET', nil)).to_s.strip
        @explicit_base_url = (base_url || ENV.fetch('BINOTEL_API_URL', nil)).to_s.strip
        @verify_ssl = verify_ssl
      end

      def configured?
        @api_key.present? && @api_secret.present?
      end

      def cabinet_mode?
        @api_key.include?('@')
      end

      def base_url
        if @explicit_base_url.present?
          @explicit_base_url.sub(%r{/+\z}, '')
        elsif cabinet_mode?
          DEFAULT_CABINET_BASE_URL
        else
          DEFAULT_REST_BASE_URL
        end
      end

      def list_of_calls_for_period(start_time:, stop_time:)
        raise ApiError, 'Binotel API client is not configured' unless configured?

        if cabinet_mode?
          fetch_cabinet_calls_for_period(start_time: start_time, stop_time: stop_time)
        else
          request_rest_json(
            'stats/list-of-calls-for-period.json',
            startTime: start_time.to_i,
            stopTime: stop_time.to_i
          )
        end
      end

      def call_record(general_call_id)
        raise ApiError, 'Binotel API client is not configured' unless configured?
        raise ApiError, 'general_call_id is blank' if general_call_id.to_s.strip.blank?

        request_rest_json(
          'stats/call-record.json',
          generalCallID: general_call_id.to_s.strip,
          callID: general_call_id.to_s.strip
        )
      end

      private

      def request_rest_json(endpoint_path, payload = {})
        normalized_path = endpoint_path.to_s.sub(%r{\A/+}, '')
        uri = URI.parse("#{base_url}/#{normalized_path}")
        request = Net::HTTP::Post.new(uri)
        request['Accept'] = 'application/json'
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate(
          payload.merge(key: @api_key, secret: @api_secret)
        )

        response = execute_http(uri, request)
        unless response.is_a?(Net::HTTPSuccess)
          raise ApiError.new(
            "Binotel API POST #{normalized_path} failed with HTTP #{response.code}",
            status: response.code.to_i,
            body: response.body.to_s
          )
        end

        parsed = parse_json_body(response.body)
        if parsed['status'].to_s == 'error'
          raise ApiError.new(
            "Binotel API error #{parsed['code']}: #{parsed['message']}",
            status: response.code.to_i,
            body: response.body.to_s,
            code: parsed['code']
          )
        end

        parsed
      end

      def fetch_cabinet_calls_for_period(start_time:, stop_time:)
        start_date = Time.zone.at(start_time.to_i).strftime('%d.%m.%Y')
        stop_date = Time.zone.at(stop_time.to_i).strftime('%d.%m.%Y')

        cookies = cabinet_session_cookies
        retried = false

        begin
          inbound_resp = cabinet_get_json(
            "/b/main/?module=cdrs&mbav=1&callType=internal&startDate=#{start_date}&stopDate=#{stop_date}&showWithoutFilters=&lang=ru",
            cookies: cookies
          )
          outbound_resp = cabinet_get_json(
            "/b/main/?module=cdrs&mbav=1&callType=external&startDate=#{start_date}&stopDate=#{stop_date}&showWithoutFilters=&lang=ru",
            cookies: cookies
          )
          missed_resp = cabinet_get_json(
            "/b/main/?module=missedCalls&mbav=1&advanced=&showWithoutFilters=&startDate=#{start_date}&stopDate=#{stop_date}",
            cookies: cookies
          )
        rescue ApiError => e
          raise if retried || e.status != 401

          retried = true
          cookies = cabinet_session_cookies(force_refresh: true)
          retry
        end

        merged_details = {}
        extract_cabinet_cdr_rows(inbound_resp, default_call_type: '0').each do |row|
          cid = (row['generalCallID'] || row['callID']).to_s
          merged_details[cid] = row if cid.present? && within_period?(row, start_time, stop_time)
        end
        extract_cabinet_cdr_rows(outbound_resp, default_call_type: '1').each do |row|
          cid = (row['generalCallID'] || row['callID']).to_s
          merged_details[cid] = row if cid.present? && within_period?(row, start_time, stop_time)
        end
        extract_cabinet_missed_rows(missed_resp).each do |row|
          cid = (row['generalCallID'] || row['callID']).to_s
          next if cid.blank? || !within_period?(row, start_time, stop_time)

          merged_details[cid] ||= row
        end

        {
          'status' => 'success',
          'callDetails' => merged_details
        }
      end

      def within_period?(row, start_time, stop_time)
        ts = row['startTime'].to_i
        return true if ts <= 0

        ts >= (start_time.to_i - 300) && ts <= (stop_time.to_i + 300)
      end

      def extract_cabinet_cdr_rows(resp, default_call_type:)
        rows = resp.dig('pageData', 'listOfCalls')
        list = case rows
               when Array then rows
               when Hash then rows.values
               else []
               end
        list.filter_map do |item|
          next unless item.is_a?(Hash)

          normalized = item.deep_stringify_keys
          normalized['callType'] = normalized['callType'].to_s.presence || default_call_type
          if normalized['pbxNumberData'].blank? && normalized['did'].present?
            normalized['pbxNumberData'] = { 'number' => normalized['did'].to_s }
          end
          normalized
        end
      end

      def extract_cabinet_missed_rows(resp)
        page_data = resp['pageData'].is_a?(Hash) ? resp['pageData'] : {}
        raw_lists = [
          page_data['listOfMissedCalls'],
          page_data['listOfProcessedMissedCalls'],
          page_data['listOfInProcessingMissedCalls']
        ]
        rows = raw_lists.flat_map do |entry|
          case entry
          when Array then entry
          when Hash then entry.values
          else []
          end
        end

        rows.filter_map do |item|
          next unless item.is_a?(Hash)

          normalized = item.deep_stringify_keys
          normalized['callType'] = '0'
          normalized['disposition'] = normalized['disposition'].to_s.presence || 'NOANSWER'
          if normalized['pbxNumberData'].blank? && normalized['did'].present?
            normalized['pbxNumberData'] = { 'number' => normalized['did'].to_s }
          end
          normalized
        end
      end

      def cabinet_session_cookies(force_refresh: false)
        cache_key = "telephony:binotel:cabinet_cookie:#{Digest::SHA256.hexdigest("#{base_url}:#{@api_key}:#{@api_secret}")[0, 24]}"
        if !force_refresh && defined?(Rails) && Rails.respond_to?(:cache) && Rails.cache
          cached = Rails.cache.read(cache_key)
          return cached if cached.present?
        end

        cookies = perform_cabinet_login!
        if defined?(Rails) && Rails.respond_to?(:cache) && Rails.cache && cookies.present?
          Rails.cache.write(cache_key, cookies, expires_in: CABINET_COOKIE_CACHE_TTL)
        end
        cookies
      end

      def perform_cabinet_login!
        cookie_jar = {}
        init_uri = URI.parse("#{base_url}/")
        init_req = Net::HTTP::Get.new(init_uri)
        init_resp = execute_http(init_uri, init_req)
        merge_set_cookies!(cookie_jar, init_resp)

        login_uri = URI.parse("#{base_url}/")
        login_req = Net::HTTP::Post.new(login_uri)
        login_req['Content-Type'] = 'application/x-www-form-urlencoded'
        login_req['Cookie'] = serialize_cookies(cookie_jar) if cookie_jar.any?
        login_req.set_form_data(
          'logining[email]' => @api_key,
          'logining[password]' => @api_secret,
          'logining[submit]' => ''
        )
        login_resp = execute_http(login_uri, login_req)
        merge_set_cookies!(cookie_jar, login_resp)

        cookie_header = serialize_cookies(cookie_jar)
        raise ApiError.new('Binotel cabinet login did not return session cookies', status: 401) if cookie_header.blank?

        verify_uri = URI.parse("#{base_url}/b/main/?module=ajax&action=getAccountData&mbav=1&app=pbx")
        verify_req = Net::HTTP::Get.new(verify_uri)
        verify_req['Accept'] = 'application/json'
        verify_req['Cookie'] = cookie_header
        verify_resp = execute_http(verify_uri, verify_req)
        merge_set_cookies!(cookie_jar, verify_resp)
        parsed = parse_json_body(verify_resp.body)
        if !verify_resp.is_a?(Net::HTTPSuccess) || (parsed['tenantId'].blank? && parsed['email'].blank?)
          raise ApiError.new('Binotel cabinet authentication failed', status: 401, body: verify_resp.body.to_s)
        end

        serialize_cookies(cookie_jar)
      end

      def cabinet_get_json(path, cookies:)
        uri = URI.parse("#{base_url}#{path}")
        req = Net::HTTP::Get.new(uri)
        req['Accept'] = 'application/json'
        req['Cookie'] = cookies
        resp = execute_http(uri, req)
        if [301, 302, 303, 307, 401, 403].include?(resp.code.to_i)
          raise ApiError.new("Binotel cabinet session expired (HTTP #{resp.code})", status: 401)
        end
        unless resp.is_a?(Net::HTTPSuccess)
          raise ApiError.new("Binotel cabinet GET #{path} failed with HTTP #{resp.code}", status: resp.code.to_i, body: resp.body.to_s)
        end

        parsed = parse_json_body(resp.body)
        if parsed['status'].to_s != 'success' && parsed['pageData'].blank?
          raise ApiError.new('Binotel cabinet returned non-JSON or unauthenticated response', status: 401, body: resp.body.to_s[0, 200])
        end

        parsed
      end

      def merge_set_cookies!(jar, response)
        Array(response.get_fields('set-cookie')).each do |raw_cookie|
          pair = raw_cookie.to_s.split(';').first.to_s.strip
          key, val = pair.split('=', 2)
          next if key.blank?

          jar[key.strip] = val.to_s.strip
        end
      end

      def serialize_cookies(jar)
        jar.map { |k, v| "#{k}=#{v}" }.join('; ')
      end

      def parse_json_body(raw_body)
        text = raw_body.to_s.strip
        return {} if text.blank?

        JSON.parse(text)
      rescue JSON::ParserError
        {}
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
