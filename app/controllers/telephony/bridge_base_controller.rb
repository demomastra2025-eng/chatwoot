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
      idempotency_key = request.headers['X-Idempotency-Key'].to_s.presence
      payload['idempotency_key'] ||= idempotency_key if idempotency_key.present?

      account_id = request.headers['X-Account-Id'].to_s.presence
      payload['account_id'] ||= account_id if account_id.present?
    end
  end

  def bearer_token
    request.authorization.to_s[/\ABearer (.+)\z/i, 1].to_s.presence
  end

  def secure_match?(provided, expected)
    provided.present? &&
      expected.present? &&
      ActiveSupport::SecurityUtils.secure_compare(provided, expected)
  end
end
