require 'digest'

class Telephony::BridgeBaseController < ApplicationController
  DEBUG_PAYLOAD_KEYS = %w[
    action app_ref call_ref call_sid direction event event_type mode number_ref provider status
  ].freeze
  DEBUG_CONTEXT_KEYS = %w[
    account_id call_ref direction event_type method number_ref path request_id
  ].freeze
  DEBUG_IDENTIFIER_KEYS = %w[app_ref call_ref call_sid number_ref].freeze
  DEBUG_IDENTIFIER_DIGEST_LENGTH = 16
  DEBUG_PAYLOAD_STRING_LIMIT = 256

  before_action :authenticate_bridge!

  private

  def authenticate_bridge!
    expected_secret = ENV.fetch('TELEPHONY_BRIDGE_SHARED_SECRET', '').to_s
    expected_token = ENV.fetch('TELEPHONY_BRIDGE_ONELINK_ACCESS_TOKEN', '').to_s.presence ||
                     ENV.fetch('TELEPHONY_BRIDGE_ACCESS_TOKEN', '').to_s.presence ||
                     expected_secret.presence
    return head :service_unavailable if expected_secret.blank? && expected_token.blank?

    provided_secret = request.headers['X-Bridge-Secret'].to_s.presence || request.headers['X-Telephony-Secret'].to_s.presence
    provided_token = bearer_token
    authorized = secure_match?(provided_secret, expected_secret) || secure_match?(provided_token, expected_token)
    return if authorized

    head :unauthorized
  end

  def request_payload
    params.to_unsafe_h.except('controller', 'action').tap do |payload|
      merge_header_value!(payload, 'idempotency_key', request.headers['X-Idempotency-Key'])
      merge_header_value!(payload, 'account_id', request.headers['X-Account-Id'])
    end
  end

  def log_telephony_debug(event:, payload:, response_payload: nil, status: nil, error: nil)
    Telephony::DebugLogger.log(
      event: event,
      payload: telephony_debug_context(payload).merge(
        request_payload: safe_telephony_debug_payload(payload),
        response_payload: safe_telephony_debug_payload(response_payload),
        status: status,
        error_class: error&.class&.name
      ).compact
    )
  end

  def bearer_token
    request.authorization.to_s[/\ABearer (.+)\z/i, 1].to_s.presence
  end

  def merge_header_value!(payload, key, raw_value)
    value = raw_value.to_s.presence
    return if value.blank?

    payload[key] = value if payload[key].blank?

    camelized_key = key.camelize(:lower)
    payload[camelized_key] = value if payload[camelized_key].blank?
  end

  def secure_match?(provided, expected)
    provided.present? &&
      expected.present? &&
      ActiveSupport::SecurityUtils.secure_compare(provided, expected)
  end

  def telephony_debug_context(payload)
    payload = payload.deep_stringify_keys

    safe_telephony_debug_payload(
      {
        request_id: request.request_id,
        method: request.method,
        path: request.path,
        account_id: payload['account_id'].presence || request.headers['X-Account-Id'].to_s.presence,
        call_ref: payload['call_ref'].presence || payload['callRef'].presence || payload['call_sid'].presence || payload['callSid'].presence,
        number_ref: payload['number_ref'].presence || payload['numberRef'].presence,
        event_type: payload['event'].presence || payload['event_type'].presence || payload['eventType'].presence,
        direction: payload['direction']
      },
      allowed_keys: DEBUG_CONTEXT_KEYS
    ).symbolize_keys
  end

  def safe_telephony_debug_payload(payload, allowed_keys: DEBUG_PAYLOAD_KEYS)
    payload.to_h.deep_stringify_keys.slice(*allowed_keys).each_with_object({}) do |(key, value), sanitized|
      safe_value = safe_telephony_debug_scalar(key, value)
      sanitized[key] = safe_value unless safe_value.nil?
    end
  end

  def safe_telephony_debug_scalar(key, value)
    if DEBUG_IDENTIFIER_KEYS.include?(key) && (value.is_a?(String) || value.is_a?(Symbol) || value.is_a?(Numeric))
      return "sha256:#{Digest::SHA256.hexdigest(value.to_s).first(DEBUG_IDENTIFIER_DIGEST_LENGTH)}"
    end

    case value
    when String, Symbol
      value.to_s.slice(0, DEBUG_PAYLOAD_STRING_LIMIT)
    when Numeric, TrueClass, FalseClass
      value
    end
  end
end
