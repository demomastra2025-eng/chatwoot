require 'digest/md5'

class Voice::Provider::Sipuni::CallbackClient
  CALL_NUMBER_URL = 'https://sipuni.com/api/callback/call_number'.freeze
  REQUEST_TIMEOUT_SECONDS = 10

  def initialize(channel)
    @channel = channel
  end

  def call_number(to:)
    response = HTTParty.post(
      CALL_NUMBER_URL,
      body: call_number_body(to),
      headers: { 'Content-Type' => 'application/x-www-form-urlencoded' },
      timeout: REQUEST_TIMEOUT_SECONDS
    )
    callback_response = Voice::Provider::Sipuni::CallbackResponse.new(response)
    validate_response!(callback_response)
    raise_outbound_failed!(callback_response, 'Sipuni did not return callback order id') if callback_response.callback_id.blank?

    {
      callback_id: callback_response.callback_id,
      status: callback_response.status,
      response: callback_response.sanitized_payload
    }
  end

  private

  attr_reader :channel

  def call_number_body(to)
    request = call_number_request(to)
    raise_outbound_not_configured!(request[:missing], to) if request[:missing].present?

    {
      'antiaon' => request[:antiaon],
      'phone' => request[:phone],
      'reverse' => request[:reverse],
      'sipnumber' => request[:sipnumber],
      'user' => request[:user],
      'hash' => call_number_hash(request)
    }
  end

  def call_number_request(to)
    {
      user: config_value(:sipuni_user_id, :system_user, :account_number, :user),
      secret: config_value(:integration_secret, :secret, :integration_key, :api_key),
      sipnumber: config_value(:default_internal_number, :sipnumber, :sip_number),
      phone: normalized_outbound_phone(to),
      reverse: binary_config_value(:reverse, default: '0'),
      antiaon: binary_config_value(:antiaon, default: '0')
    }.then { |request| request.merge(missing: missing_request_fields(request)) }
  end

  def call_number_hash(request)
    Digest::MD5.hexdigest(
      [
        request[:antiaon],
        request[:phone],
        request[:reverse],
        request[:sipnumber],
        request[:user],
        request[:secret]
      ].join('+')
    )
  end

  def missing_request_fields(request)
    {
      account_number: request[:user],
      integration_secret: request[:secret],
      default_internal_number: request[:sipnumber],
      phone: request[:phone]
    }.filter_map { |key, value| key.to_s if value.blank? }
  end

  def config
    @config ||= channel.provider_config_hash.with_indifferent_access
  end

  def config_value(*keys)
    keys.each do |key|
      value = config[key].to_s.strip
      return value if value.present?
    end

    nil
  end

  def binary_config_value(key, default:)
    value = config[key].to_s.strip
    return value if value.in?(%w[0 1])

    default
  end

  def normalized_outbound_phone(value)
    digits = value.to_s.gsub(/\D/, '')
    digits = digits.delete_prefix('00')
    digits = "7#{digits[1..]}" if digits.length == 11 && digits.start_with?('8')
    return if digits.length < 7

    digits
  end

  def validate_response!(callback_response)
    raise_outbound_failed!(callback_response, 'Sipuni outbound callback request failed') unless callback_response.http_success?

    return unless callback_response.provider_error?

    message = ['Sipuni rejected outbound callback request', callback_response.provider_message].compact_blank.join(': ')
    raise_outbound_failed!(callback_response, message)
  end

  def raise_outbound_not_configured!(missing, to)
    raise Telephony::Error.new(
      code: 'SIPUNI_OUTBOUND_NOT_CONFIGURED',
      message: "Sipuni outbound callback is not configured: #{missing.join(', ')}",
      status: :unprocessable_content,
      details: {
        provider: 'sipuni',
        phone_number: channel.phone_number,
        to: to,
        missing: missing
      }.compact
    )
  end

  def raise_outbound_failed!(callback_response, message)
    raise Telephony::Error.new(
      code: 'SIPUNI_OUTBOUND_FAILED',
      message: message,
      status: :bad_gateway,
      details: {
        provider: 'sipuni',
        http_status: callback_response.http_status,
        response: callback_response.sanitized_payload
      }.compact
    )
  end
end
