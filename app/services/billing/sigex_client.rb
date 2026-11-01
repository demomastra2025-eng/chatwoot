# frozen_string_literal: true

require 'base64'
require 'json'
require 'net/http'
require 'uri'

class Billing::SigexClient
  class ApiError < StandardError; end

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 15

  def sign_payload!(document_payload)
    uri = build_https_uri('/api/sign')
    req = Net::HTTP::Post.new(
      uri,
      'Accept' => 'application/json',
      'Content-Type' => 'application/json',
      'Authorization' => "Bearer #{Billing::Config.sigex_api_token}"
    )
    req.body = JSON.generate({ data: Base64.strict_encode64(JSON.generate(document_payload)) })
    parsed = perform_json_request(uri, req)
    {
      cms_signature: (parsed['signature'] || parsed['cms']).to_s.presence || raise(ApiError, 'SIGEX signature missing'),
      sign_id: parsed['sign_id'].to_s.presence
    }
  end

  private

  def build_https_uri(path)
    base = Billing::Config.sigex_base_url.to_s.chomp('/')
    raise ApiError, 'SIGEX is not configured' if base.blank? || Billing::Config.sigex_api_token.blank?

    uri = URI("#{base}#{path}")
    raise ApiError, 'SIGEX requires HTTPS' unless uri.scheme == 'https'

    uri
  end

  def perform_json_request(uri, req)
    res = Net::HTTP.start(
      uri.hostname, uri.port,
      use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_PEER,
      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT
    ) { |http| http.request(req) }
    raise ApiError, "SIGEX HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    JSON.parse(res.body)
  rescue JSON::ParserError
    raise ApiError, 'SIGEX returned invalid JSON'
  rescue StandardError => e
    raise e if e.is_a?(ApiError)

    raise ApiError, e.message.to_s.gsub(Billing::Config.sigex_api_token.to_s, '[REDACTED]').slice(0, 200)
  end
end
