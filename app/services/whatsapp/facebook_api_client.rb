require 'openssl'

class Whatsapp::FacebookApiClient
  BASE_URI = 'https://graph.facebook.com'.freeze

  class << self
    def appsecret_proof_query(access_token)
      proof = appsecret_proof(access_token)
      return {} if proof.blank?

      { appsecret_proof: proof }
    end

    def appsecret_proof(access_token)
      return nil unless ActiveModel::Type::Boolean.new.cast(ENV.fetch('WHATSAPP_GRAPH_APPSECRET_PROOF', false))
      return nil if access_token.blank?

      app_secret = GlobalConfigService.load('WHATSAPP_APP_SECRET', '')
      return nil if app_secret.blank?

      OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), app_secret, access_token)
    end
  end

  class Error < StandardError
    attr_reader :payload, :status

    def initialize(message, response)
      @payload = response.parsed_response if response.respond_to?(:parsed_response)
      @status = response.code if response.respond_to?(:code)

      super("#{message}: #{response.body}")
    end
  end

  def initialize(access_token = nil)
    @access_token = access_token
    @api_version = GlobalConfigService.load('WHATSAPP_API_VERSION', 'v22.0')
  end

  def exchange_code_for_token(code)
    response = HTTParty.get(
      "#{BASE_URI}/#{@api_version}/oauth/access_token",
      query: {
        client_id: GlobalConfigService.load('WHATSAPP_APP_ID', ''),
        client_secret: GlobalConfigService.load('WHATSAPP_APP_SECRET', ''),
        code: code
      }
    )

    handle_response(response, 'Token exchange failed')
  end

  def fetch_phone_numbers(waba_id, after: nil)
    query = query_with_access_token
    query[:after] = after if after.present?

    response = HTTParty.get(
      "#{BASE_URI}/#{@api_version}/#{waba_id}/phone_numbers",
      query: query
    )

    handle_response(response, 'WABA phone numbers fetch failed')
  end

  def debug_token(input_token)
    response = HTTParty.get(
      "#{BASE_URI}/#{@api_version}/debug_token",
      query: {
        input_token: input_token,
        access_token: build_app_access_token
      }
    )

    handle_response(response, 'Token validation failed')
  end

  def register_phone_number(phone_number_id, pin)
    response = HTTParty.post(
      "#{BASE_URI}/#{@api_version}/#{phone_number_id}/register",
      headers: request_headers,
      query: appsecret_proof_query,
      body: { messaging_product: 'whatsapp', pin: pin.to_s }.to_json
    )

    handle_response(response, 'Phone registration failed')
  end

  def phone_number_verified?(phone_number_id)
    response = HTTParty.get(
      "#{BASE_URI}/#{@api_version}/#{phone_number_id}",
      headers: request_headers,
      query: appsecret_proof_query
    )

    data = handle_response(response, 'Phone status check failed')
    data['code_verification_status'] == 'VERIFIED'
  end

  def subscribe_waba_webhook(waba_id, callback_url, verify_token)
    # Step 1: Subscribe app to WABA first (required before override)
    # Meta requires the app to be subscribed before using override_callback_uri
    # See: https://github.com/chatwoot/chatwoot/issues/13097
    subscribe_app_to_waba(waba_id)

    # Step 2: Override callback URL for this specific WABA
    override_waba_callback(waba_id, callback_url, verify_token)
  end

  def subscribe_app_to_waba(waba_id)
    response = HTTParty.post(
      "#{BASE_URI}/#{@api_version}/#{waba_id}/subscribed_apps",
      headers: request_headers,
      query: appsecret_proof_query
    )

    handle_response(response, 'App subscription to WABA failed')
  end

  def override_waba_callback(waba_id, callback_url, verify_token)
    response = HTTParty.post(
      "#{BASE_URI}/#{@api_version}/#{waba_id}/subscribed_apps",
      headers: request_headers,
      query: appsecret_proof_query,
      body: {
        override_callback_uri: callback_url,
        verify_token: verify_token,
        subscribed_fields: webhook_subscribed_fields
      }.to_json
    )

    handle_response(response, 'Webhook callback override failed')
  end

  def unsubscribe_waba_webhook(waba_id)
    response = HTTParty.delete(
      "#{BASE_URI}/#{@api_version}/#{waba_id}/subscribed_apps",
      headers: request_headers,
      query: appsecret_proof_query
    )

    handle_response(response, 'Webhook unsubscription failed')
  end

  def webhook_subscribed_fields
    %w[messages smb_message_echoes]
  end

  private

  def request_headers
    {
      'Authorization' => "Bearer #{@access_token}",
      'Content-Type' => 'application/json'
    }
  end

  def build_app_access_token
    app_id = GlobalConfigService.load('WHATSAPP_APP_ID', '')
    app_secret = GlobalConfigService.load('WHATSAPP_APP_SECRET', '')
    "#{app_id}|#{app_secret}"
  end

  def query_with_access_token
    { access_token: @access_token }.merge(appsecret_proof_query)
  end

  def appsecret_proof_query
    self.class.appsecret_proof_query(@access_token)
  end

  def handle_response(response, error_message)
    raise Error.new(error_message, response) unless response.success?

    response.parsed_response
  end
end

Whatsapp::FacebookApiClient.prepend_mod_with('Whatsapp::FacebookApiClient')
