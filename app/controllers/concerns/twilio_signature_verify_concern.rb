module TwilioSignatureVerifyConcern
  extend ActiveSupport::Concern

  included do
    before_action :verify_twilio_signature!
  end

  private

  def verify_twilio_signature!
    return if valid_twilio_signature?

    Rails.logger.warn("[Twilio] Rejected webhook with invalid signature for AccountSid=#{twilio_account_sid_for_log}")
    head :unauthorized
  end

  def valid_twilio_signature?
    signature = request.headers['X-Twilio-Signature'].presence
    return false if signature.blank?

    channel = twilio_signature_channel
    return false if channel&.auth_token.blank?

    auth_tokens = twilio_signature_auth_tokens(channel)
    return false if auth_tokens.blank?

    auth_tokens.any? do |auth_token|
      validator = Twilio::Security::RequestValidator.new(auth_token)
      twilio_signature_urls.any? do |signature_url|
        validator.validate(signature_url, twilio_signature_params, signature)
      end
    end
  rescue StandardError => e
    Rails.logger.warn("[Twilio] Signature validation failed: #{e.class.name}")
    false
  end

  def twilio_signature_auth_tokens(channel)
    [stored_twilio_signature_auth_token(channel), configured_twilio_account_auth_token].compact.uniq
  end

  def stored_twilio_signature_auth_token(channel)
    return if channel.api_key_sid.present?

    channel.auth_token
  end

  def configured_twilio_account_auth_token
    ENV.fetch('TWILIO_ACCOUNT_AUTH_TOKEN', nil).presence || ENV.fetch('TWILIO_AUTH_TOKEN', nil).presence
  end

  def twilio_signature_urls
    [request.original_url, public_twilio_signature_url].compact.uniq
  end

  def public_twilio_signature_url
    public_base_url = ENV.fetch('FRONTEND_URL', nil).presence
    return if public_base_url.blank?

    uri = URI.parse(public_base_url)
    uri.path = request.path
    uri.query = request.query_string.presence
    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

  def twilio_signature_params
    request.request_parameters.to_h
  end

  def twilio_signature_channel
    account_sid = twilio_signature_value('AccountSid')
    return if account_sid.blank?

    channel_scope = Channel::TwilioSms.where(account_sid: account_sid)
    find_twilio_channel_by_messaging_service(channel_scope) ||
      find_twilio_channel_by_phone_number(channel_scope) ||
      channel_scope.order(:id).first
  end

  def find_twilio_channel_by_messaging_service(channel_scope)
    messaging_service_sid = twilio_signature_value('MessagingServiceSid')
    return if messaging_service_sid.blank?

    channel_scope.find_by(messaging_service_sid: messaging_service_sid)
  end

  def find_twilio_channel_by_phone_number(channel_scope)
    phone_number = twilio_signature_value('To').presence || twilio_signature_value('From').presence
    return if phone_number.blank?

    channel_scope.find_by(phone_number: phone_number)
  end

  def twilio_signature_value(key)
    twilio_signature_params[key] || twilio_signature_params[key.to_sym]
  end

  def twilio_account_sid_for_log
    twilio_signature_value('AccountSid').presence || 'unknown'
  end
end
