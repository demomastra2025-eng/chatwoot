require 'rails_helper'

RSpec.describe Meta::CredentialDataSanitizer do
  describe '.sanitize' do
    it 'recursively removes credential-bearing keys without mutating the input' do
      input = {
        'status' => 'invalid',
        'nested' => {
          'access_token' => 'secret-access-token',
          'api_key' => 'secret-api-key',
          'refresh_token' => 'secret-refresh-token',
          'oauth_code' => 'one-time-code',
          'verification_pin' => '123456',
          'token' => 'bare-token',
          'message' => 'provider failure'
        }
      }

      result = described_class.sanitize(input)

      expect(result).to eq('status' => 'invalid', 'nested' => { 'message' => 'provider failure' })
      expect(input.dig('nested', 'access_token')).to eq('secret-access-token')
    end

    it 'redacts known secret values and common credential representations in strings' do
      secret = 'known-provider-token'
      input = <<~TEXT
        token=#{secret} access_token=query-token code=one-time-code Authorization: Bearer bearer-token
        verification_pin=123456 {"client_secret":"json-secret","refresh_token":"refresh-secret","pin":"654321"}
      TEXT

      result = described_class.sanitize(input, secrets: [secret])

      expect(result).not_to include(secret, 'query-token', 'one-time-code', 'bearer-token', 'json-secret', 'refresh-secret', '123456', '654321')
      expect(result).to include(
        'token=[FILTERED]', 'access_token=[FILTERED]', 'code=[FILTERED]', 'Bearer [FILTERED]', 'verification_pin=[FILTERED]'
      )
    end

    it 'redacts generic webhook verify tokens from structured and string representations' do
      input = {
        'webhook_verify_token' => 'hash-secret',
        'message' => <<~TEXT
          webhook_verify_token=query-secret
          {"webhook_verify_token":"json-secret"}
          webhook_verify_token: labeled-secret
        TEXT
      }

      result = described_class.sanitize(input)

      expect(result).not_to have_key('webhook_verify_token')
      expect(result.fetch('message')).not_to include('query-secret', 'json-secret', 'labeled-secret')
      expect(result.fetch('message').scan('[FILTERED]').size).to eq(3)
    end

    it 'redacts short PIN values only when they are labeled as credentials' do
      result = described_class.sanitize('Registration PIN 123456 is invalid; order 654321 remains visible')

      expect(result).to eq('Registration PIN [FILTERED] is invalid; order 654321 remains visible')
    end
  end
end
