# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

class Billing::BccOpenApiClient
  class ApiError < StandardError; end

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 15

  def fetch_access_token
    ensure_configured!
    uri = build_https_uri('/oauth/token')
    req = Net::HTTP::Post.new(uri, 'Accept' => 'application/json')
    req.set_form_data(
      'grant_type' => 'client_credentials',
      'client_id' => Billing::Config.bcc_open_api_client_id,
      'client_secret' => Billing::Config.bcc_open_api_client_secret
    )
    parsed = perform_json_request(uri, req)
    parsed['access_token'].to_s.presence || raise(ApiError, 'BCC Open API OAuth token missing in response')
  end

  def fetch_credit_transactions(from:, to:, cursor: nil)
    token = fetch_access_token
    query = URI.encode_www_form(statement_query_params(from, to, cursor))
    uri = build_https_uri("/statements?#{query}")
    req = Net::HTTP::Get.new(uri, 'Accept' => 'application/json', 'Authorization' => "Bearer #{token}")
    parsed = perform_json_request(uri, req)
    rows = Array(parsed['transactions'] || parsed['items'] || parsed['data'])
    {
      transactions: rows.filter_map { |row| normalize_transaction_row(row) },
      next_cursor: parsed['next_cursor'].presence
    }
  end

  def register_invoice(invoice)
    token = fetch_access_token
    uri = build_https_uri('/invoices')
    req = Net::HTTP::Post.new(
      uri,
      'Accept' => 'application/json',
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{token}"
    )
    req.body = JSON.generate(register_invoice_payload(invoice))
    parsed = perform_json_request(uri, req)
    external_id = (parsed['invoice_id'] || parsed['id']).to_s.presence || raise(ApiError, 'BCC Open API invoice ID missing')
    {
      external_invoice_id: external_id,
      payment_url: parsed['payment_url'].to_s.presence
    }
  end

  private

  def ensure_configured!
    raise ApiError, 'BCC Open API is not configured' unless Billing::Config.bcc_open_api_configured?
  end

  def build_https_uri(path)
    base = Billing::Config.bcc_open_api_base_url.to_s.chomp('/')
    uri = URI("#{base}#{path}")
    raise ApiError, 'BCC Open API requires HTTPS' unless uri.scheme == 'https'

    uri
  end

  def statement_query_params(from, to, cursor)
    params = {
      'iban' => Billing::Config.bcc_business_iban,
      'from' => from.respond_to?(:iso8601) ? from.iso8601 : from.to_s,
      'to' => to.respond_to?(:iso8601) ? to.iso8601 : to.to_s,
      'direction' => 'credit'
    }
    params['cursor'] = cursor if cursor.present?
    params
  end

  def register_invoice_payload(invoice)
    document = Billing::CompletionState.new(invoice).context['document'].to_h
    {
      invoice_number: invoice.invoice_number,
      supplier_iban: document['supplier_iban'],
      supplier_bin: document['supplier_bin'],
      payer_bin: invoice.payer_tax_id,
      payer_name: invoice.payer_legal_name,
      amount: invoice.amount_kzt.to_s('F'),
      currency: invoice.currency,
      knp: invoice.knp_code,
      payment_purpose: invoice.payment_purpose,
      due_on: invoice.due_on.iso8601
    }
  end

  def perform_json_request(uri, req)
    res = Net::HTTP.start(
      uri.hostname, uri.port,
      use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_PEER,
      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT
    ) { |http| http.request(req) }
    raise ApiError, "BCC Open API HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    res.body.present? ? JSON.parse(res.body) : {}
  rescue JSON::ParserError
    raise ApiError, 'BCC Open API returned invalid JSON'
  rescue StandardError => e
    raise e if e.is_a?(ApiError)

    raise ApiError, sanitize_error(e.message)
  end

  def sanitize_error(message)
    redacted = message.to_s.dup
    [Billing::Config.bcc_open_api_client_secret, Billing::Config.bcc_open_api_client_id].compact.each do |secret|
      redacted.gsub!(secret, '[REDACTED]')
    end
    redacted.gsub(/Bearer\s+\S+/i, 'Bearer [REDACTED]').slice(0, 200)
  end

  def normalize_transaction_row(row)
    return nil unless row.is_a?(Hash)

    ref_id = first_string(row, 'bank_reference_id', 'reference_id', 'id', 'document_id')
    amount_minor = extract_amount_minor(row)
    return nil if ref_id.blank? || amount_minor <= 0

    build_normalized_transaction(row, ref_id, amount_minor)
  end

  def build_normalized_transaction(row, ref_id, amount_minor)
    {
      bank_reference_id: ref_id,
      amount_minor: amount_minor,
      currency: (first_string(row, 'currency') || Billing::DEFAULT_CURRENCY).upcase,
      sender_tax_id: first_string(row, 'sender_tax_id', 'payer_bin', 'counterparty_bin'),
      sender_name: first_string(row, 'sender_name', 'payer_name', 'counterparty_name'),
      payment_purpose: first_string(row, 'payment_purpose', 'purpose', 'details').to_s,
      occurred_at: parse_occurred_at(first_string(row, 'occurred_at', 'valued_at', 'date')),
      raw_payload: row
    }
  end

  def first_string(row, *keys)
    keys.each do |key|
      val = row[key].to_s.strip
      return val if val.present?
    end
    nil
  end

  def extract_amount_minor(row)
    return row['amount_minor'].to_i if row['amount_minor'].present?

    Billing.kzt_to_minor(row['amount'] || 0)
  end

  def parse_occurred_at(raw)
    return Time.current if raw.blank?

    Time.zone.parse(raw.to_s) || Time.current
  rescue ArgumentError
    Time.current
  end
end
