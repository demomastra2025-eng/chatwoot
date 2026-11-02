# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'uri'

class Billing::BccEcomClient
  class ApiError < StandardError; end

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 15
  APPROVED_STATUSES = %w[approved paid captured success 00].freeze

  class << self
    def normalize_charge_response(parsed)
      status_str = (parsed['status'] || parsed['response_code']).to_s.strip.downcase
      approved = parsed['approved'] == true || APPROVED_STATUSES.include?(status_str)
      ref_id = (parsed['bank_reference_id'] || parsed['reference_id'] || parsed['rrn'] || parsed['transaction_id']).to_s.strip.presence
      {
        approved: approved,
        bank_reference_id: ref_id,
        status: status_str.presence || 'declined',
        message: parsed['message'].to_s.slice(0, 160),
        raw_payload: parsed.except('card_token')
      }
    end

    def compute_signature(raw_body, secret_key = Billing::Config.bcc_ecom_secret_key)
      OpenSSL::HMAC.hexdigest('SHA256', secret_key.to_s, raw_body.to_s)
    end

    def valid_signature?(raw_body:, signature:, secret_key: Billing::Config.bcc_ecom_secret_key)
      return false if secret_key.blank? || signature.blank?

      expected = compute_signature(raw_body, secret_key).downcase
      supplied = signature.to_s.strip.delete_prefix('sha256=').downcase
      supplied.bytesize == expected.bytesize && OpenSSL.fixed_length_secure_compare(expected, supplied)
    end
  end

  def build_payment_url(invoice)
    return nil unless Billing::Config.bcc_ecom_configured?

    base = Billing::Config.bcc_ecom_base_url.to_s.chomp('/')
    params = checkout_params(invoice)
    canonical = URI.encode_www_form(params)
    sig = self.class.compute_signature(canonical)
    "#{base}/checkout?#{canonical}&signature=#{sig}"
  end

  def charge_recurring!(invoice:, card_token:)
    ensure_configured!(card_token)
    uri = build_https_uri('/recurring/charge')
    body = JSON.generate(recurring_payload(invoice, card_token))
    req = Net::HTTP::Post.new(
      uri,
      'Accept' => 'application/json',
      'Content-Type' => 'application/json',
      'X-BCC-Signature' => self.class.compute_signature(body)
    )
    req.body = body
    parsed = perform_json_request(uri, req, card_token)
    self.class.normalize_charge_response(parsed)
  end

  private

  def ensure_configured!(card_token)
    raise ApiError, 'BCC Ecom is not configured' unless Billing::Config.bcc_ecom_configured?
    raise ApiError, 'Card token is missing' if card_token.blank?
  end

  def build_https_uri(path)
    base = Billing::Config.bcc_ecom_base_url.to_s.chomp('/')
    uri = URI("#{base}#{path}")
    raise ApiError, 'BCC Ecom requires HTTPS' unless uri.scheme == 'https'

    uri
  end

  def checkout_params(invoice)
    {
      'merchant_id' => Billing::Config.bcc_ecom_merchant_id,
      'terminal_id' => Billing::Config.bcc_ecom_terminal_id,
      'order_id' => invoice.invoice_number,
      'amount_minor' => invoice.amount_minor.to_s,
      'currency' => invoice.currency
    }
  end

  def recurring_payload(invoice, card_token)
    {
      merchant_id: Billing::Config.bcc_ecom_merchant_id,
      terminal_id: Billing::Config.bcc_ecom_terminal_id,
      order_id: invoice.invoice_number,
      amount_minor: invoice.amount_minor,
      currency: invoice.currency,
      card_token: card_token,
      description: invoice.payment_purpose
    }
  end

  def perform_json_request(uri, req, card_token)
    res = Net::HTTP.start(
      uri.hostname, uri.port,
      use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_PEER,
      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT
    ) { |http| http.request(req) }
    raise ApiError, "BCC Ecom HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    res.body.present? ? JSON.parse(res.body) : {}
  rescue JSON::ParserError
    raise ApiError, 'BCC Ecom returned invalid JSON'
  rescue StandardError => e
    raise e if e.is_a?(ApiError)

    raise ApiError, sanitize_error(e.message, card_token)
  end

  def sanitize_error(message, card_token)
    redacted = message.to_s.dup
    [Billing::Config.bcc_ecom_secret_key, card_token].compact.each do |secret|
      redacted.gsub!(secret, '[REDACTED]')
    end
    redacted.slice(0, 200)
  end
end
