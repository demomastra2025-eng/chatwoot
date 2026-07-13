require 'rails_helper'

RSpec.describe Meta::AuthorizationErrorClassifier do
  describe '.classify' do
    it 'classifies OAuth code 190 as requiring reauthorization and keeps the subcode' do
      result = described_class.classify(
        error: {
          code: 190,
          error_subcode: 460,
          type: 'OAuthException',
          message: 'The session has been invalidated',
          fbtrace_id: 'trace-id'
        }
      )

      expect(result).to be_action_required
      expect(result).to be_confirmed_invalid
      expect(result.kind).to eq(:reauthorization_required)
      expect(result.error).to include('code' => 190, 'error_subcode' => 460, 'fbtrace_id' => 'trace-id')
    end

    it 'keeps an ambiguous OAuth 190 unconfirmed until a provider health probe corroborates it' do
      result = described_class.classify(error: { code: 190, type: 'OAuthException', message: 'Error validating access token' })

      expect(result.kind).to eq(:reauthorization_required)
      expect(result).not_to be_confirmed_invalid
    end

    it 'classifies Meta throttling and HTTP 5xx as transient' do
      expect(described_class.classify({ error: { code: 4 } })).to be_transient
      expect(described_class.classify({ error: { code: 999 } }, http_status: 503)).to be_transient
    end

    it 'classifies missing permissions separately from invalid credentials' do
      result = described_class.classify(error: { code: 10, message: 'Permission denied' })

      expect(result).to be_action_required
      expect(result.kind).to eq(:permission_missing)
    end

    it 'does not force reauthorization for unknown provider errors' do
      result = described_class.classify(error: { code: 100, message: 'Unknown object' })

      expect(result.kind).to eq(:unknown)
      expect(result).not_to be_action_required
      expect(result).not_to be_transient
    end
  end
end
