# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

class Billing::IsEsfClient
  class ApiError < StandardError; end

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 15

  def issue_esf!(esf_payload:, cms_signature:)
    uri = build_https_uri('/api/v1/esf')
    req = Net::HTTP::Post.new(
      uri,
      'Accept' => 'application/json',
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{Billing::Config.esf_api_token}"
    )
    req.body = JSON.generate({ esf: esf_payload, signature: cms_signature })
    parsed = perform_json_request(uri, req)
    esf_id = (parsed['esf_id'] || parsed['registration_number'] || parsed['id']).to_s.presence ||
             raise(ApiError, 'IS ESF registration id missing')
    { esf_id: esf_id, status: 'issued' }
  end

  private

  def build_https_uri(path)
    base = Billing::Config.esf_base_url.to_s.chomp('/')
    raise ApiError, 'IS ESF is not configured' if base.blank? || Billing::Config.esf_api_token.blank?

    uri = URI("#{base}#{path}")
    raise ApiError, 'IS ESF requires HTTPS' unless uri.scheme == 'https'

    uri
  end

  def perform_json_request(uri, req)
    res = Net::HTTP.start(
      uri.hostname, uri.port,
      use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_PEER,
      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT
    ) { |http| http.request(req) }
    raise ApiError, "IS ESF HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    JSON.parse(res.body)
  rescue JSON::ParserError
    raise ApiError, 'IS ESF returned invalid JSON'
  rescue StandardError => e
    raise e if e.is_a?(ApiError)

    raise ApiError, e.message.to_s.gsub(Billing::Config.esf_api_token.to_s, '[REDACTED]').slice(0, 200)
  end
end
