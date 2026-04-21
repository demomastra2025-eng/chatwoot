class Telephony::BridgeBaseController < ApplicationController
  before_action :authenticate_bridge!

  private

  def authenticate_bridge!
    expected_secret = ENV.fetch('TELEPHONY_BRIDGE_SHARED_SECRET', '').to_s
    expected_token = ENV.fetch('TELEPHONY_BRIDGE_ACCESS_TOKEN', '').to_s.presence || expected_secret.presence
    return if expected_secret.blank? && expected_token.blank?

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
        request_payload: payload,
        response_payload: response_payload,
        status: status,
        error_class: error&.class&.name,
        error_message: error&.message
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

    {
      request_id: request.request_id,
      method: request.method,
      path: request.path,
      account_id: payload['account_id'].presence || request.headers['X-Account-Id'].to_s.presence,
      call_ref: payload['call_ref'].presence || payload['callRef'].presence || payload['call_sid'].presence || payload['callSid'].presence,
      number_ref: payload['number_ref'].presence || payload['numberRef'].presence,
      event_type: payload['event'].presence || payload['event_type'].presence || payload['eventType'].presence,
      direction: payload['direction']
    }.compact
  end
end
