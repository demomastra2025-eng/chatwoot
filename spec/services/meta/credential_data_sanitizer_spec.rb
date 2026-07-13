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
        {"client_secret":"json-secret","refresh_token":"refresh-secret"}
      TEXT

      result = described_class.sanitize(input, secrets: [secret])

      expect(result).not_to include(secret, 'query-token', 'one-time-code', 'bearer-token', 'json-secret', 'refresh-secret')
      expect(result).to include('token=[FILTERED]', 'access_token=[FILTERED]', 'code=[FILTERED]', 'Bearer [FILTERED]')
    end
  end
end
