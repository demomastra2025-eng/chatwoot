require 'rails_helper'

RSpec.describe 'Telephony Webphone API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:voice_phone_number) { "+1555#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}" }
  let(:voice_channel) { create(:channel_voice, :fonoster, account: account, phone_number: voice_phone_number) }
  let(:voice_inbox) { voice_channel.inbox }
  let(:path) { "/api/v1/accounts/#{account.id}/telephony/webphone/token" }

  before do
    account.enable_features!('channel_voice')
  end

  it 'returns a browser webphone contract without an inbox when the operator binding exists' do
    create(
      :telephony_agent_binding,
      account: account,
      user: administrator,
      provider: 'fonoster',
      agent_ref: 'fonoster-agent-42'
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, 'https://bridge.example/telephony/webphone/token')
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s })
        .to_return(
          status: 200,
          body: {
            token: 'test-token',
            username: 'agent-42',
            domain: 'agents.example.test',
            displayName: 'Operator 42',
            signalingServer: 'wss://bridge.example/ws',
            targetAor: 'sip:agent-42@agents.example.test'
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      post path, headers: headers, as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'provider')).to eq('fonoster')
    expect(response.parsed_body.dig('payload', 'calling_supported')).to be(true)
    expect(response.parsed_body.dig('payload', 'agent_ref')).to eq('fonoster-agent-42')
  end

  it 'does not advertise browser calling for fonoster without a complete browser contract' do
    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, 'https://bridge.example/telephony/webphone/token')
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s })
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

  it 'keeps browser calling disabled when the bridge sends callingSupported false' do
    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, 'https://bridge.example/telephony/webphone/token')
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s })
        .to_return(
          status: 200,
          body: {
            provider: 'fonoster',
            callingSupported: false,
            token: 'test-token',
            username: 'agent-303',
            domain: 'agents.example.test',
            signalingServer: 'wss://bridge.example/ws',
            targetAor: 'sip:agent-303@agents.example.test'
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

  it 'advertises browser calling for fonoster when the bridge returns the required SIP contract' do
    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, 'https://bridge.example/telephony/webphone/token')
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s })
        .to_return(
          status: 200,
          body: {
            token: 'test-token',
            provider: 'fonoster',
            username: 'agent-101',
            domain: 'agents.example.test',
            displayName: 'Operator 101',
            signalingServer: 'wss://bridge.example/ws',
            targetAor: 'sip:agent-101@agents.example.test'
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
    expect(response.parsed_body.dig('payload', 'calling_supported')).to be(true)
    expect(response.parsed_body.dig('payload', 'targetAor')).to eq('sip:agent-101@agents.example.test')
  end

  it 'uses the configured public signaling server override for fonoster browser calls' do
    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret',
      TELEPHONY_WEBPHONE_SIGNALING_SERVER_URL: 'wss://app.example.test/telephony/sip-ws'
    ) do
      stub_request(:post, 'https://bridge.example/telephony/webphone/token')
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s })
        .to_return(
          status: 200,
          body: {
            token: 'test-token',
            provider: 'fonoster',
            username: 'agent-101',
            domain: 'agents.example.test',
            displayName: 'Operator 101',
            signalingServer: 'ws://bridge.example:5062',
            targetAor: 'sip:agent-101@agents.example.test'
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
    expect(response.parsed_body.dig('payload', 'calling_supported')).to be(true)
    expect(response.parsed_body.dig('payload', 'signalingServer')).to eq('wss://app.example.test/telephony/sip-ws')
  end
end
