# frozen_string_literal: true

class Webhooks::BccEcomController < ActionController::API
  def process_payload
    raw_body = request.raw_post.to_s
    return head :unauthorized unless valid_hmac?(raw_body)

    payload = parse_json_payload(raw_body)
    return head :bad_request unless payload

    return render json: { status: 'ignored' }, status: :ok unless approved_payment?(payload)

    card_token = payload['card_token']
    sanitized_payload = Billing.sanitize_sensitive_payload(payload)
    event = Billing::PaymentMatcher.new(source: 'bcc_ecom', payload: sanitized_payload).perform
    persist_card_token_if_opted_in!(event, payload, card_token)
    render json: { status: 'ok', event_status: event.status, billing_invoice_id: event.billing_invoice_id }, status: :ok
  end

  private

  def valid_hmac?(raw_body)
    return false unless Billing::Config.bcc_ecom_configured?

    signature = request.headers['X-BCC-Signature'].presence || request.headers['X-Signature'].presence
    Billing::BccEcomClient.valid_signature?(raw_body: raw_body, signature: signature)
  end

  def parse_json_payload(raw_body)
    parsed = JSON.parse(raw_body)
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError
    nil
  end

  def approved_payment?(payload)
    status = (payload['status'] || payload['response_code']).to_s.strip.downcase
    payload['approved'] == true || Billing::BccEcomClient::APPROVED_STATUSES.include?(status)
  end

  def persist_card_token_if_opted_in!(event, payload, card_token)
    return unless eligible_for_card_save?(event, payload, card_token)

    profile = event.account&.billing_account_profile
    return unless profile

    profile.update!(
      bcc_card_token: card_token.to_s.strip,
      bcc_card_masked: payload['card_masked'].to_s.strip.presence || profile.bcc_card_masked,
      autopay_enabled: true
    )
  end

  def eligible_for_card_save?(event, payload, card_token)
    event.status == 'matched' && payload['save_card'] == true && card_token.present? && valid_merchant_id?(payload)
  end

  def valid_merchant_id?(payload)
    return true if payload['merchant_id'].blank?

    payload['merchant_id'].to_s == Billing::Config.bcc_ecom_merchant_id.to_s
  end
end
