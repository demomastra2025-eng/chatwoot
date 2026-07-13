require 'rails_helper'

RSpec.describe Meta::AuthorizationHealthCheckService do
  before do
    allow(GlobalConfigService).to receive(:load) do |key, default|
      {
        'INSTAGRAM_API_VERSION' => 'v22.0',
        'INSTAGRAM_APP_ID' => 'ig-app',
        'FACEBOOK_API_VERSION' => 'v25.0',
        'FB_APP_ID' => 'fb-app',
        'FB_APP_SECRET' => 'fb-secret',
        'WHATSAPP_API_VERSION' => 'v22.0'
      }.fetch(key, default)
    end
    allow(Whatsapp::FacebookApiClient).to receive(:appsecret_proof_query).and_return({})
  end

  describe 'Instagram' do
    let(:channel) do
      build_stubbed(:channel_instagram, access_token: 'ig-token', instagram_id: 'ig-123', expires_at: 20.days.from_now)
    end

    it 'requires both matching identity and app subscription' do
      stub_request(:get, 'https://graph.instagram.com/v22.0/me')
        .with(query: hash_including('access_token' => 'ig-token'))
        .to_return(status: 200, body: { id: 'ig-123', username: 'company' }.to_json, headers: { 'Content-Type' => 'application/json' })
      stub_request(:get, 'https://graph.instagram.com/v22.0/ig-123/subscribed_apps')
        .with(query: hash_including('access_token' => 'ig-token'))
        .to_return(status: 200, body: { data: [{ id: 'ig-app' }] }.to_json, headers: { 'Content-Type' => 'application/json' })

      result = described_class.new(channel).result

      expect(result).to be_healthy
      expect(result.metadata).to include('asset_id' => 'ig-123', 'subscription_present' => true)
    end

    it 'marks a locally expired token as action required without a Graph request' do
      channel.expires_at = 1.minute.ago

      result = described_class.new(channel).result

      expect(result).to be_action_required
      expect(result.reason).to eq('token_expired')
      expect(a_request(:get, /graph\.instagram\.com/)).not_to have_been_made
    end

    it 'preserves OAuth subcode details for invalid authorization' do
      stub_request(:get, 'https://graph.instagram.com/v22.0/me')
        .with(query: hash_including('access_token' => 'ig-token'))
        .to_return(
          status: 400,
          body: { error: { code: 190, error_subcode: 460, type: 'OAuthException', message: 'Session invalidated', fbtrace_id: 'trace' } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = described_class.new(channel).result

      expect(result).to be_action_required
      expect(result.error).to include('code' => 190, 'error_subcode' => 460, 'fbtrace_id' => 'trace')
    end

    it 'does not require reconnection for transient Meta failures' do
      stub_request(:get, 'https://graph.instagram.com/v22.0/me')
        .with(query: hash_including('access_token' => 'ig-token'))
        .to_return(status: 503, body: { error: { code: 2, message: 'Temporary service issue' } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      result = described_class.new(channel).result

      expect(result).to be_transient
      expect(result).not_to be_action_required
    end

    it 'treats a malformed successful identity response as transient' do
      stub_request(:get, 'https://graph.instagram.com/v22.0/me')
        .with(query: hash_including('access_token' => 'ig-token'))
        .to_return(status: 200, body: {}.to_json, headers: { 'Content-Type' => 'application/json' })

      result = described_class.new(channel).result

      expect(result).to be_transient
      expect(result.reason).to eq('provider_response_invalid')
    end

    it 'treats a malformed successful subscription response as transient' do
      stub_request(:get, 'https://graph.instagram.com/v22.0/me')
        .with(query: hash_including('access_token' => 'ig-token'))
        .to_return(status: 200, body: { id: 'ig-123' }.to_json, headers: { 'Content-Type' => 'application/json' })
      stub_request(:get, 'https://graph.instagram.com/v22.0/ig-123/subscribed_apps')
        .with(query: hash_including('access_token' => 'ig-token'))
        .to_return(status: 200, body: {}.to_json, headers: { 'Content-Type' => 'application/json' })

      result = described_class.new(channel).result

      expect(result).to be_transient
      expect(result.reason).to eq('provider_response_invalid')
    end

    it 'distinguishes missing webhook subscription from invalid credentials' do
      stub_request(:get, 'https://graph.instagram.com/v22.0/me')
        .with(query: hash_including('access_token' => 'ig-token'))
        .to_return(status: 200, body: { id: 'ig-123' }.to_json, headers: { 'Content-Type' => 'application/json' })
      stub_request(:get, 'https://graph.instagram.com/v22.0/ig-123/subscribed_apps')
        .with(query: hash_including('access_token' => 'ig-token'))
        .to_return(status: 200, body: { data: [] }.to_json, headers: { 'Content-Type' => 'application/json' })

      result = described_class.new(channel).result

      expect(result).to be_degraded
      expect(result.reason).to eq('subscription_missing')
    end
  end

  describe 'Facebook Page' do
    let(:channel) do
      build_stubbed(:channel_facebook_page, page_access_token: 'page-token', page_id: 'page-123')
    end

    def stub_facebook_debug(overrides = {})
      data = {
        is_valid: true,
        app_id: 'fb-app',
        expires_at: 30.days.from_now.to_i,
        data_access_expires_at: 60.days.from_now.to_i,
        scopes: Meta::FacebookTokenHealthCheckService::REQUIRED_SCOPES
      }.merge(overrides)
      stub_request(:get, 'https://graph.facebook.com/v25.0/debug_token')
        .with(query: hash_including('input_token' => 'page-token', 'access_token' => 'fb-app|fb-secret'))
        .to_return(status: 200, body: { data: data }.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    it 'verifies token app binding, permissions, exact page identity, and app subscription' do
      stub_facebook_debug
      stub_request(:get, 'https://graph.facebook.com/v25.0/page-123')
        .with(query: hash_including('access_token' => 'page-token'))
        .to_return(status: 200, body: { id: 'page-123' }.to_json, headers: { 'Content-Type' => 'application/json' })
      stub_request(:get, 'https://graph.facebook.com/v25.0/page-123/subscribed_apps')
        .with(query: hash_including('access_token' => 'page-token'))
        .to_return(status: 200, body: { data: [{ id: 'fb-app' }] }.to_json, headers: { 'Content-Type' => 'application/json' })

      expect(described_class.new(channel).result).to be_healthy
    end

    it 'rejects access to a different page asset' do
      stub_facebook_debug
      stub_request(:get, 'https://graph.facebook.com/v25.0/page-123')
        .with(query: hash_including('access_token' => 'page-token'))
        .to_return(status: 200, body: { id: 'other-page' }.to_json, headers: { 'Content-Type' => 'application/json' })

      result = described_class.new(channel).result

      expect(result).to be_action_required
      expect(result.reason).to eq('asset_mismatch')
    end

    it 'requires the token to be bound to the configured app' do
      stub_facebook_debug(app_id: 'other-app')

      result = described_class.new(channel).result

      expect(result).to be_action_required
      expect(result.reason).to eq('app_mismatch')
    end

    it 'requires the permissions needed for messaging and webhook management' do
      stub_facebook_debug(scopes: ['pages_messaging'])

      result = described_class.new(channel).result

      expect(result).to be_action_required
      expect(result.reason).to eq('permission_missing')
      expect(result.metadata['missing_scopes']).to contain_exactly('pages_manage_metadata')
    end

    it 'requires unexpired data access' do
      stub_facebook_debug(data_access_expires_at: 1.minute.ago.to_i)

      result = described_class.new(channel).result

      expect(result).to be_action_required
      expect(result.reason).to eq('data_access_expired')
    end

    it 'treats malformed token-expiry fields in a successful debug response as transient' do
      stub_facebook_debug(expires_at: 'not-a-unix-time')

      result = described_class.new(channel).result

      expect(result).to be_transient
      expect(result.reason).to eq('provider_response_invalid')
      expect(a_request(:get, 'https://graph.facebook.com/v25.0/page-123')).not_to have_been_made
    end

    it 'treats malformed data-access expiry as transient' do
      stub_facebook_debug(data_access_expires_at: 'invalid')

      result = described_class.new(channel).result

      expect(result).to be_transient
      expect(result.reason).to eq('provider_response_invalid')
    end
  end

  describe 'WhatsApp Cloud' do
    let(:channel) do
      build_stubbed(:channel_whatsapp, provider: 'whatsapp_cloud', provider_config: {
                      'api_key' => 'wa-token', 'phone_number_id' => 'phone-123'
                    })
    end

    it 'verifies exact phone-number access' do
      stub_request(:get, 'https://graph.facebook.com/v22.0/phone-123')
        .with(query: hash_including('access_token' => 'wa-token'))
        .to_return(status: 200, body: { id: 'phone-123' }.to_json, headers: { 'Content-Type' => 'application/json' })

      expect(described_class.new(channel).result).to be_healthy
    end
  end

  it 'treats transport exceptions as transient, redacts tokens, and caches the result' do
    channel = build_stubbed(:channel_instagram, access_token: 'secret-token', instagram_id: 'ig-123', expires_at: 20.days.from_now)
    allow(HTTParty).to receive(:get).and_raise(StandardError, 'request failed access_token=secret-token')
    service = described_class.new(channel)

    result = service.result

    expect(service.result).to equal(result)
    expect(HTTParty).to have_received(:get).once
    expect(result).to be_transient
    expect(result.error['message']).to include('[FILTERED]')
    expect(result.error['message']).not_to include('secret-token')
  end
end
