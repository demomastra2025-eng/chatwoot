# frozen_string_literal: true

class Voice::Provider::Sipuni::CallbackResponse
  CALLBACK_ID_KEYS = %w[callbackId callback_id callId call_id id orderId order_id].freeze
  SENSITIVE_RESPONSE_KEYS = %w[hash secret integration_secret integration_key api_key].freeze
  STATUS_MAP = {
    'accepted' => 'ringing',
    'success' => 'ringing',
    'ok' => 'ringing',
    'queued' => 'created',
    'initiated' => 'created',
    'ringing' => 'ringing',
    'answered' => 'in_progress',
    'in-progress' => 'in_progress',
    'in_progress' => 'in_progress',
    'completed' => 'completed',
    'busy' => 'busy',
    'no-answer' => 'no_answer',
    'no_answer' => 'no_answer',
    'cancelled' => 'cancelled',
    'canceled' => 'cancelled',
    'failed' => 'failed'
  }.freeze

  def initialize(response)
    @response = response
  end

  def callback_id
    callback_id_from(payload)
  end

  def status
    value = payload[:status].presence || payload[:state].presence
    return if value.blank?

    STATUS_MAP[value.to_s.downcase] || value.to_s
  end

  def sanitized_payload
    sanitize_response(payload)
  end

  def http_success?
    return response.success? if response.respond_to?(:success?)

    http_status.to_i.between?(200, 299)
  end

  def provider_error?
    return true if payload[:success] == false

    status_value = payload[:status].presence || payload[:result].presence || payload[:success].presence
    return true if status_value.to_s.downcase.in?(%w[error failed fail false])

    payload[:error].present?
  end

  def http_status
    response.respond_to?(:code) ? response.code : nil
  end

  private

  attr_reader :response

  def payload
    @payload ||= parsed_response
  end

  def parsed_response
    decoded = decode_response_payload(raw_response_payload)
    return decoded.with_indifferent_access if decoded.is_a?(Hash)

    { value: decoded.to_s }.with_indifferent_access
  rescue JSON::ParserError
    { raw: response.respond_to?(:body) ? response.body.to_s : '' }.with_indifferent_access
  end

  def raw_response_payload
    parsed = response.respond_to?(:parsed_response) ? response.parsed_response : nil
    return parsed if parsed.present?
    return response.body if response.respond_to?(:body) && response.body.present?

    nil
  end

  def decode_response_payload(raw_payload)
    return JSON.parse(raw_payload) if raw_payload.is_a?(String) && raw_payload.present?

    raw_payload
  end

  def callback_id_from(response_payload)
    CALLBACK_ID_KEYS.each do |key|
      value = response_payload[key]
      return value.to_s if value.present?
    end

    nested_response_payloads(response_payload).each do |nested_payload|
      nested_callback_id = callback_id_from(nested_payload)
      return nested_callback_id if nested_callback_id.present?
    end

    nil
  end

  def nested_response_payloads(response_payload)
    %i[data payload response result].filter_map do |key|
      nested_payload = response_payload[key]
      nested_payload.with_indifferent_access if nested_payload.is_a?(Hash)
    end
  end

  def sanitize_response(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, item), sanitized|
        next if SENSITIVE_RESPONSE_KEYS.include?(key.to_s)

        sanitized[key.to_s] = sanitize_response(item)
      end
    when Array
      value.map { |item| sanitize_response(item) }
    else
      value
    end
  end
end
