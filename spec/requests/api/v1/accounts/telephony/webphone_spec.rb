require 'rails_helper'

RSpec.describe 'Telephony Webphone API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:voice_channel) { create(:channel_voice, :fonoster, account: account, phone_number: '+15551230000') }
  let(:voice_inbox) { voice_channel.inbox }
  let(:path) { "/api/v1/accounts/#{account.id}/telephony/webphone/token" }

  before do
    account.enable_features!('channel_voice')
  end

  it 'does not advertise browser calling for fonoster even when the bridge returns calling_supported' do
    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, 'https://bridge.example/telephony/webphone/token')
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret' })
        .to_return(
          status: 200,
          body: {
            token: 'test-token',
            provider: 'fonoster',
            calling_supported: true
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      post path,
           params: { inbox_id: voice_inbox.id },
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'provider')).to eq('fonoster')
    expect(response.parsed_body.dig('payload', 'calling_supported')).to be(false)
  end
end
