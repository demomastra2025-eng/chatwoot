# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

class Billing::UchetEdoClient
  class ApiError < StandardError; end

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 15

  def send_eavr!(eavr_payload:, cms_signature:)
    uri = build_https_uri('/api/v1/eavr')
    req = Net::HTTP::Post.new(
      uri,
      'Accept' => 'application/json',
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{Billing::Config.uchet_edo_api_token}"
    )
    req.body = JSON.generate({ document: eavr_payload, signature: cms_signature })
    parsed = perform_json_request(uri, req)
    doc_id = (parsed['document_id'] || parsed['id']).to_s.presence || raise(ApiError, 'Uchet.EDO document_id missing')
    { document_id: doc_id, status: parsed['status'].presence || 'sent_for_signature' }
  end

  private

  def build_https_uri(path)
    base = Billing::Config.uchet_edo_base_url.to_s.chomp('/')
    raise ApiError, 'Uchet.EDO is not configured' if base.blank? || Billing::Config.uchet_edo_api_token.blank?

    uri = URI("#{base}#{path}")
    raise ApiError, 'Uchet.EDO requires HTTPS' unless uri.scheme == 'https'

    uri
  end

  def perform_json_request(uri, req)
    res = Net::HTTP.start(
      uri.hostname, uri.port,
      use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_PEER,
      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT
    ) { |http| http.request(req) }
    raise ApiError, "Uchet.EDO HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    JSON.parse(res.body)
  rescue JSON::ParserError
    raise ApiError, 'Uchet.EDO returned invalid JSON'
  rescue StandardError => e
    raise e if e.is_a?(ApiError)

    raise ApiError, e.message.to_s.gsub(Billing::Config.uchet_edo_api_token.to_s, '[REDACTED]').slice(0, 200)
  end
end
