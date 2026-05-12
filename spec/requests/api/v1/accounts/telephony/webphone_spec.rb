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

  it 'normalizes test-grade bridge SIP identity to the current operator binding' do
    create(
      :telephony_agent_binding,
      account: account,
      user: administrator,
      provider: 'fonoster',
      agent_ref: 'fonoster-agent-1001',
      agent_aor: 'sip:1001@operator.cloud.vconsult.kz'
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, 'https://bridge.example/telephony/webphone/token')
        .with(
          body: hash_including(
            agent_ref: 'fonoster-agent-1001',
            agent_aor: 'sip:1001@operator.cloud.vconsult.kz'
          ),
          headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s }
        )
        .to_return(
          status: 200,
          body: {
            token: 'test-token',
            username: 'internal',
            domain: 'internal',
            displayName: 'Test Call Agent',
            signalingServer: 'wss://bridge.example/ws',
            targetAor: 'sip:voice@default'
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
    expect(response.parsed_body.dig('payload', 'username')).to eq('1001')
    expect(response.parsed_body.dig('payload', 'domain')).to eq('operator.cloud.vconsult.kz')
    expect(response.parsed_body.dig('payload', 'targetAor')).to eq('sip:1001@operator.cloud.vconsult.kz')
    expect(response.parsed_body.dig('payload', 'calling_supported')).to be(true)
  end

  it 'records browser registration presence on the agent binding' do
    agent_binding = create(:telephony_agent_binding, account: account, user: administrator, provider: 'fonoster')

    post "/api/v1/accounts/#{account.id}/telephony/webphone/presence",
         params: { registered: true },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(agent_binding.reload.registered_for_routing?).to be(true)
    expect(agent_binding.metadata).to include(
      'registration_state' => 'registered',
      'presence' => 'online',
      'last_presence_source' => 'browser_webphone'
    )
    expect(response.parsed_body.dig('payload', 'registered_for_routing')).to be(true)
  end

  it 'does not advertise browser calling without an operator binding even when the bridge contract is complete' do
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
            username: 'agent-404',
            domain: 'agents.example.test',
            signalingServer: 'wss://bridge.example/ws',
            targetAor: 'sip:agent-404@agents.example.test'
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      post path, headers: headers, as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'calling_supported')).to be(false)
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
    create(:telephony_agent_binding, account: account, user: administrator, provider: 'fonoster')

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
    create(:telephony_agent_binding, account: account, user: administrator, provider: 'fonoster')

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

  it 'claims an incoming operator pool call for the current registered candidate' do
    agent_binding = create(:telephony_agent_binding, :registered, account: account, user: administrator, provider: 'fonoster')
    call_session = create(
      :telephony_call_session,
      account: account,
      external_call_ref: 'operator-pool-claim-1',
      status: 'ringing',
      metadata: {
        'metadata' => {
          'operator_candidate_user_ids' => [administrator.id],
          'operator_candidate_agent_refs' => [agent_binding.agent_ref]
        }
      }
    )

    post "/api/v1/accounts/#{account.id}/telephony/webphone/claim",
         params: { call_ref: call_session.external_call_ref },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'claimed')).to be(true)
    expect(call_session.reload).to have_attributes(
      agent_binding_id: agent_binding.id,
      answered_by: "user:#{administrator.id}",
      status: 'connecting'
    )
    expect(call_session.metadata.dig('operator_claim', 'user_id')).to eq(administrator.id)
  end

  it 'rejects the second operator when an incoming call was already claimed' do
    winner = create(:telephony_agent_binding, :registered, account: account, user: administrator, provider: 'fonoster')
    loser_user = create(:user, account: account, role: :agent)
    loser_headers = loser_user.create_new_auth_token
    loser = create(:telephony_agent_binding, :registered, account: account, user: loser_user, provider: 'fonoster')
    call_session = create(
      :telephony_call_session,
      account: account,
      external_call_ref: 'operator-pool-claim-2',
      status: 'ringing',
      metadata: {
        'metadata' => {
          'operator_candidate_user_ids' => [administrator.id, loser_user.id],
          'operator_candidate_agent_refs' => [winner.agent_ref, loser.agent_ref]
        }
      }
    )

    post "/api/v1/accounts/#{account.id}/telephony/webphone/claim",
         params: { call_ref: call_session.external_call_ref },
         headers: headers,
         as: :json
    expect(response).to have_http_status(:ok)

    post "/api/v1/accounts/#{account.id}/telephony/webphone/claim",
         params: { call_ref: call_session.external_call_ref },
         headers: loser_headers,
         as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('CALL_ALREADY_CLAIMED')
    expect(response.parsed_body.dig('details', 'user_id')).to eq(administrator.id)
    expect(call_session.reload.agent_binding_id).to eq(winner.id)
  end

  it 'rejects claim attempts from registered operators outside the route candidate pool' do
    agent_binding = create(:telephony_agent_binding, :registered, account: account, user: administrator, provider: 'fonoster')
    call_session = create(
      :telephony_call_session,
      account: account,
      external_call_ref: 'operator-pool-claim-3',
      status: 'ringing',
      metadata: {
        'metadata' => {
          'operator_candidate_user_ids' => [administrator.id + 10_000],
          'operator_candidate_agent_refs' => [agent_binding.agent_ref]
        }
      }
    )

    post "/api/v1/accounts/#{account.id}/telephony/webphone/claim",
         params: { call_ref: call_session.external_call_ref },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['code']).to eq('OPERATOR_NOT_CANDIDATE')
    expect(call_session.reload.agent_binding_id).to be_nil
  end
end
