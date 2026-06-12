# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Meta::AuthorizationHealthCheckService do
  subject(:service) { described_class.new(channel) }

  let(:headers) { { 'Content-Type' => 'application/json' } }

  describe '#healthy?' do
    context 'with an Instagram channel' do
      let(:channel) do
        build(:channel_instagram, access_token: 'ig-token', instagram_id: 'ig-123', expires_at: 20.days.from_now)
      end

      before do
        allow(GlobalConfigService).to receive(:load).with('INSTAGRAM_API_VERSION', 'v22.0').and_return('v22.0')
      end

      it 'returns true only when the token and webhook subscription are accepted by Meta' do
        stub_request(:get, 'https://graph.instagram.com/v22.0/me')
          .with(query: { fields: 'id,username', access_token: 'ig-token' })
          .to_return(status: 200, body: { id: 'ig-123', username: 'clinic' }.to_json, headers: headers)
        stub_request(:get, 'https://graph.instagram.com/v22.0/ig-123/subscribed_apps')
          .with(query: { access_token: 'ig-token' })
          .to_return(status: 200, body: { data: [{ id: 'app-1' }] }.to_json, headers: headers)

        expect(service.healthy?).to be(true)
      end

      it 'returns false when Meta rejects the token' do
        stub_request(:get, 'https://graph.instagram.com/v22.0/me')
          .with(query: { fields: 'id,username', access_token: 'ig-token' })
          .to_return(status: 400, body: { error: { code: 190, type: 'OAuthException' } }.to_json, headers: headers)

        expect(service.healthy?).to be(false)
      end

      it 'returns false when the webhook subscription edge is empty' do
        stub_request(:get, 'https://graph.instagram.com/v22.0/me')
          .with(query: { fields: 'id,username', access_token: 'ig-token' })
          .to_return(status: 200, body: { id: 'ig-123', username: 'clinic' }.to_json, headers: headers)
        stub_request(:get, 'https://graph.instagram.com/v22.0/ig-123/subscribed_apps')
          .with(query: { access_token: 'ig-token' })
          .to_return(status: 200, body: { data: [] }.to_json, headers: headers)

        expect(service.healthy?).to be(false)
      end
    end

    context 'with a Facebook page channel' do
      let(:channel) do
        build(:channel_facebook_page, page_id: 'page-123', page_access_token: 'page-token')
      end

      before do
        allow(GlobalConfigService).to receive(:load).with('FACEBOOK_API_VERSION', 'v18.0').and_return('v18.0')
      end

      it 'returns true when the page token can read the configured page' do
        stub_request(:get, 'https://graph.facebook.com/v18.0/page-123')
          .with(query: { fields: 'id', access_token: 'page-token' })
          .to_return(status: 200, body: { id: 'page-123' }.to_json, headers: headers)

        expect(service.healthy?).to be(true)
      end

      it 'returns false when Meta rejects the page token' do
        stub_request(:get, 'https://graph.facebook.com/v18.0/page-123')
          .with(query: { fields: 'id', access_token: 'page-token' })
          .to_return(status: 400, body: { error: { code: 190, type: 'OAuthException' } }.to_json, headers: headers)

        expect(service.healthy?).to be(false)
      end
    end

    context 'with a WhatsApp Cloud channel' do
      let(:channel) do
        build(
          :channel_whatsapp,
          provider: 'whatsapp_cloud',
          validate_provider_config: false,
          sync_templates: false,
          provider_config: {
            'api_key' => 'wa-token',
            'phone_number_id' => 'phone-123',
            'business_account_id' => 'waba-123',
            'source' => 'embedded_signup'
          }
        )
      end

      before do
        allow(GlobalConfigService).to receive(:load).with('WHATSAPP_API_VERSION', 'v22.0').and_return('v22.0')
        allow(Whatsapp::FacebookApiClient).to receive(:appsecret_proof_query).with('wa-token').and_return({})
      end

      it 'returns true when the phone number token probe succeeds' do
        stub_request(:get, 'https://graph.facebook.com/v22.0/phone-123')
          .with(query: { fields: 'id', access_token: 'wa-token' })
          .to_return(status: 200, body: { id: 'phone-123' }.to_json, headers: headers)

        expect(service.healthy?).to be(true)
      end

      it 'returns false when Meta rejects the WhatsApp token' do
        stub_request(:get, 'https://graph.facebook.com/v22.0/phone-123')
          .with(query: { fields: 'id', access_token: 'wa-token' })
          .to_return(status: 401, body: { error: { code: 190, type: 'OAuthException' } }.to_json, headers: headers)

        expect(service.healthy?).to be(false)
      end
    end
  end
end
