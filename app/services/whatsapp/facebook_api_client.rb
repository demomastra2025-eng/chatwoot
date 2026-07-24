require 'openssl'

class Whatsapp::FacebookApiClient
  BASE_URI = 'https://graph.facebook.com'.freeze
  include Whatsapp::FacebookApiClientWebhookFields
  include Whatsapp::FacebookApiClientWebhookSubscriptionHelpers
  WEBHOOK_DEFAULT_FIELDS = Whatsapp::FacebookApiClientWebhookFields::FIELDS
  COEXISTENCE_WEBHOOK_FIELDS = %w[history smb_app_state_sync].freeze

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

    def initialize(message, response, secrets: [])
      payload = response.parsed_response if response.respond_to?(:parsed_response)
      @payload = Meta::CredentialDataSanitizer.sanitize(payload, secrets: secrets)
      @status = response.code if response.respond_to?(:code)
      safe_body = Meta::CredentialDataSanitizer.sanitize(response.body.to_s, secrets: secrets)

      super("#{message}: #{safe_body}")
    end
  end

  class WebhookRecoveryAnchorRequiredError < StandardError; end
  class WebhookSubscriptionCompensationError < WebhookRecoveryAnchorRequiredError; end
  class WebhookCallbackOutcomeUnknownError < WebhookRecoveryAnchorRequiredError; end

  def initialize(access_token = nil)
    @access_token = access_token
    @api_version = GlobalConfigService.load('WHATSAPP_API_VERSION', 'v25.0')
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

    handle_response(response, 'Token exchange failed', secrets: [code])
  end

  def fetch_phone_numbers(waba_id, after: nil, fields: nil)
    query = appsecret_proof_query
    query[:after] = after if after.present?
    query[:fields] = Array(fields).join(',') if fields.present?

    response = HTTParty.get(
      "#{BASE_URI}/#{@api_version}/#{waba_id}/phone_numbers",
      headers: request_headers,
      query: query
    )

    handle_response(response, 'WABA phone numbers fetch failed')
  end

  def request_smb_app_data(phone_number_id, sync_type)
    response = HTTParty.post(
      "#{BASE_URI}/#{@api_version}/#{phone_number_id}/smb_app_data",
      headers: request_headers,
      query: appsecret_proof_query,
      body: { messaging_product: 'whatsapp', sync_type: sync_type }.to_json
    )

    handle_response(response, "#{sync_type} synchronization request failed")
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

  def webhook_subscribed_fields(coexistence: false)
    fields = WEBHOOK_DEFAULT_FIELDS.dup
    fields.concat(COEXISTENCE_WEBHOOK_FIELDS) if coexistence
    fields.uniq
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

  def appsecret_proof_query
    self.class.appsecret_proof_query(@access_token)
  end

  def handle_response(response, error_message, secrets: [])
    raise Error.new(error_message, response, secrets: error_secrets + secrets) unless response.success?

    response.parsed_response
  end

  def error_secrets
    [@access_token, GlobalConfigService.load('WHATSAPP_APP_SECRET', ''), build_app_access_token]
  end
end

Whatsapp::FacebookApiClient.prepend_mod_with('Whatsapp::FacebookApiClient')
