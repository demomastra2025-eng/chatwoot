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
            token: unsigned_jwt(
              'username' => '1001',
              'domain' => 'operator.cloud.vconsult.kz',
              'targetAor' => 'sip:1001@operator.cloud.vconsult.kz',
              'allowedMethods' => ['INVITE']
            ),
            username: '1001',
            domain: 'operator.cloud.vconsult.kz',
            displayName: 'Legacy Browser Agent',
            signalingServer: 'wss://bridge.example/ws',
            targetAor: 'sip:1001@operator.cloud.vconsult.kz'
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

  it 'uses the inbox SIP profile for the webphone contract when the user also has a legacy binding' do
    create(
      :telephony_agent_binding,
      account: account,
      user: administrator,
      provider: 'fonoster',
      agent_ref: 'legacy-agent-1001',
      agent_aor: 'sip:1001@operator.cloud.vconsult.kz'
    )
    create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: administrator,
      internal_extension: '504',
      agent_ref: 'local-profile-504',
      fonoster_agent_ref: 'remote-profile-504',
      agent_aor: 'sip:504@ats01.kz.sipuni.com',
      availability_mode: 'external_extension'
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, 'https://bridge.example/telephony/webphone/token')
        .with(
          body: hash_including(
            agent_ref: 'remote-profile-504',
            agent_aor: 'sip:504@ats01.kz.sipuni.com'
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

    payload = response.parsed_body['payload']
    expect(payload['agent_ref']).to eq('remote-profile-504')
    expect(payload['username']).to eq('504')
    expect(payload['domain']).to eq('ats01.kz.sipuni.com')
    expect(payload['targetAor']).to eq('sip:504@ats01.kz.sipuni.com')
    expect(payload['browser_join_supported']).to be(false)
    expect(payload['calling_supported']).to be(false)
  end

  it 'returns a Janus SIP webphone contract for native Sipuni browser profiles' do
    provider_connection = create(
      :telephony_provider_connection,
      account: account,
      provider_kind: 'sipuni',
      host: 'ats01.kz.sipuni.com',
      port: 5060,
      transport: 'udp',
      username: '990001000021'
    )
    sipuni_channel = create(
      :channel_voice,
      account: account,
      provider: 'sipuni',
      phone_number: '+15551231999',
      provider_config: {
        provider_kind: 'sipuni',
        provider_connection_id: provider_connection.id,
        number_ref: 'sipuni-browser-number-ref',
        routing_mode: 'operator',
        operator_distribution_mode: 'broadcast'
      }
    )
    sipuni_inbox = sipuni_channel.inbox
    create(:inbox_member, inbox: sipuni_inbox, user: administrator)
    create(
      :telephony_sip_profile,
      account: account,
      inbox: sipuni_inbox,
      user: administrator,
      internal_extension: '501',
      provider_connection: provider_connection,
      sip_username: '990001000021',
      sip_password: 'test-sip-password',
      sip_host: 'operator.cloud.vconsult.kz',
      agent_ref: 'local-profile-501',
      fonoster_agent_ref: nil,
      availability_mode: 'browser_webphone',
      status: 'active',
      agent_aor: 'sip:990001000021@ats01.kz.sipuni.com',
      metadata: {
        registration_state: 'registered',
        registered: true,
        last_presence_event_at: Time.current.iso8601
      }
    )

    with_modified_env(
      TELEPHONY_JANUS_WS_URL: 'wss://dev.one-link.kz/janus-sipuni',
      TELEPHONY_JANUS_ICE_SERVERS_JSON: "'[{\"urls\":\"stun:stun.l.google.com:19302\"}]'"
    ) do
      post path,
           params: { inbox_id: sipuni_inbox.id },
           headers: headers,
           as: :json
    end

    payload = response.parsed_body.fetch('payload')
    expect(response).to have_http_status(:ok)
    expect(payload['provider']).to eq('sipuni')
    expect(payload['janus_server']).to eq('wss://dev.one-link.kz/janus-sipuni')
    expect(payload['sip']).to include(
      'username' => '990001000021',
      'auth_username' => '990001000021',
      'password' => 'test-sip-password',
      'host' => 'ats01.kz.sipuni.com',
      'port' => 5060,
      'transport' => 'udp',
      'uri' => 'sip:990001000021@ats01.kz.sipuni.com',
      'proxy' => 'sip:ats01.kz.sipuni.com:5060',
      'internal_extension' => '501'
    )
    expect(payload['sipUsername']).to eq('990001000021')
    expect(payload['sipPassword']).to eq('test-sip-password')
    expect(payload['ice_servers']).to eq([{ 'urls' => 'stun:stun.l.google.com:19302' }])
    expect(payload['browser_join_supported']).to be(true)
    expect(payload['calling_supported']).to be(true)
    expect(payload['registered_for_routing']).to be(true)
  end

  it 'returns an unsupported payload for provider-managed Sipuni extensions' do
    sipuni_channel = create(
      :channel_voice,
      :fonoster,
      account: account,
      phone_number: '+15550129999',
      provider_config: { provider_kind: 'sipuni', number_ref: 'sipuni-number-ref' }
    )
    sipuni_inbox = sipuni_channel.inbox
    create(:inbox_member, inbox: sipuni_inbox, user: administrator)
    create(
      :telephony_sip_profile,
      account: account,
      inbox: sipuni_inbox,
      user: administrator,
      internal_extension: '501',
      availability_mode: 'external_extension',
      status: 'active',
      agent_aor: 'sip:501@ats01.kz.sipuni.com'
    )

    post path,
         params: { inbox_id: sipuni_inbox.id },
         headers: headers,
         as: :json

    payload = response.parsed_body.fetch('payload')
    expect(response).to have_http_status(:ok)
    expect(payload['reason']).to eq('provider_managed_external_extension')
    expect(payload['browser_join_supported']).to be(false)
    expect(payload['calling_supported']).to be(false)
    expect(payload['registered_for_routing']).to be(true)
  end

  it 'returns an unsupported payload for provider-managed Binotel extensions' do
    binotel_channel = create(
      :channel_voice,
      :fonoster,
      account: account,
      phone_number: '+15550001755',
      provider_config: { provider_kind: 'binotel', number_ref: 'binotel-number-ref' }
    )
    binotel_inbox = binotel_channel.inbox
    create(:inbox_member, inbox: binotel_inbox, user: administrator)
    create(
      :telephony_sip_profile,
      account: account,
      inbox: binotel_inbox,
      user: administrator,
      internal_extension: '207',
      availability_mode: 'external_extension',
      status: 'active',
      agent_aor: 'sip:207@sip53.binotel.example'
    )

    post path,
         params: { inbox_id: binotel_inbox.id },
         headers: headers,
         as: :json

    payload = response.parsed_body.fetch('payload')
    expect(response).to have_http_status(:ok)
    expect(payload['reason']).to eq('provider_managed_external_extension')
    expect(payload['browser_join_supported']).to be(false)
    expect(payload['calling_supported']).to be(false)
    expect(payload['registered_for_routing']).to be(true)
  end

  it 'uses the latest browser SIP profile for no-inbox auto webphone bootstrap' do
    older_voice_channel = create(
      :channel_voice,
      :fonoster,
      account: account,
      phone_number: "+1556#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}"
    )
    create(
      :telephony_sip_profile,
      account: account,
      inbox: older_voice_channel.inbox,
      user: administrator,
      internal_extension: '9098',
      agent_ref: 'local-profile-9098',
      fonoster_agent_ref: 'remote-profile-9098',
      agent_aor: 'sip:9098@operator.cloud.vconsult.kz',
      availability_mode: 'browser_webphone'
    )
    create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: administrator,
      internal_extension: '505',
      agent_ref: 'local-profile-505',
      fonoster_agent_ref: 'remote-profile-505',
      agent_aor: 'sip:505@operator.cloud.vconsult.kz',
      availability_mode: 'browser_webphone'
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:post, 'https://bridge.example/telephony/webphone/token')
        .with(
          body: hash_including(
            agent_ref: 'remote-profile-505',
            agent_aor: 'sip:505@operator.cloud.vconsult.kz'
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

      post path, headers: headers, as: :json
    end

    payload = response.parsed_body['payload']
    expect(payload['agent_ref']).to eq('remote-profile-505')
    expect(payload['username']).to eq('505')
    expect(payload['domain']).to eq('operator.cloud.vconsult.kz')
    expect(payload['targetAor']).to eq('sip:505@operator.cloud.vconsult.kz')
    expect(payload['browser_join_supported']).to be(true)
    expect(payload['calling_supported']).to be(true)
  end

  it 'does not fall back to a hidden account binding for a managed inbox without a SIP profile' do
    create(
      :telephony_agent_binding,
      account: account,
      user: administrator,
      provider: 'fonoster',
      agent_ref: 'legacy-agent-1001',
      agent_aor: 'sip:1001@operator.cloud.vconsult.kz'
    )
    voice_inbox.telephony_number_binding.update!(
      managed_by: Telephony::NumberBinding::MANAGED_BY_ONELINK,
      ownership_status: 'local'
    )

    token_request = nil
    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      token_request = stub_request(:post, 'https://bridge.example/telephony/webphone/token')

      post path,
           params: { inbox_id: voice_inbox.id },
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(token_request).not_to have_been_requested
    expect(response.parsed_body['payload']).to include(
      'provider' => 'fonoster',
      'calling_supported' => false,
      'registered' => false,
      'registered_for_routing' => false,
      'reason' => 'agent_binding_missing'
    )
  end

  it 'disables browser calling when a signed Fonoster token still points at the test identity' do
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
        .to_return(
          status: 200,
          body: {
            token: unsigned_jwt(
              'username' => 'internal',
              'domain' => 'internal',
              'targetAor' => 'sip:voice@default',
              'aorLink' => 'sip:voice@default',
              'allowedMethods' => ['INVITE']
            ),
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

    payload = response.parsed_body['payload']
    expect(payload['username']).to eq('1001')
    expect(payload['domain']).to eq('operator.cloud.vconsult.kz')
    expect(payload['targetAor']).to eq('sip:1001@operator.cloud.vconsult.kz')
    expect(payload['calling_supported']).to be(false)
    expect(payload.dig('diagnostics', 'token_identity_mismatch')).to be(true)
    expect(payload.dig('diagnostics', 'actual_token_identity')).to include(
      'username' => 'internal',
      'domain' => 'internal',
      'targetAor' => 'sip:voice@default'
    )
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
    expect(response.parsed_body.dig('payload', 'calling_supported')).to be(true)
    expect(response.parsed_body.dig('payload', 'registered_for_routing')).to be(true)
  end

  it 'does not write browser presence to a disabled legacy binding without an inbox' do
    disabled_binding = create(
      :telephony_agent_binding,
      account: account,
      user: administrator,
      provider: 'fonoster',
      enabled: false,
      metadata: {
        'disabled_reason' => 'managed_voice_inboxes_do_not_use_legacy_bindings',
        'registration_state' => 'offline'
      }
    )

    post "/api/v1/accounts/#{account.id}/telephony/webphone/presence",
         params: { registered: true },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(disabled_binding.reload.metadata).to include(
      'disabled_reason' => 'managed_voice_inboxes_do_not_use_legacy_bindings',
      'registration_state' => 'offline'
    )
    expect(response.parsed_body['payload']).to include(
      'calling_supported' => false,
      'registered_for_routing' => false,
      'reason' => 'agent_binding_missing'
    )
  end

  it 'records browser registration presence on the current inbox SIP profile' do
    legacy_binding = create(
      :telephony_agent_binding,
      account: account,
      user: administrator,
      provider: 'fonoster',
      agent_ref: 'legacy-agent-1001',
      agent_aor: 'sip:1001@operator.cloud.vconsult.kz'
    )
    sip_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: administrator,
      internal_extension: '504',
      agent_ref: 'local-profile-504',
      fonoster_agent_ref: 'remote-profile-504',
      agent_aor: 'sip:504@operator.cloud.vconsult.kz',
      availability_mode: 'browser_webphone'
    )

    post "/api/v1/accounts/#{account.id}/telephony/webphone/presence",
         params: { registered: true, inbox_id: voice_inbox.id },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(sip_profile.reload.registered_for_routing?).to be(true)
    expect(legacy_binding.reload.metadata).not_to include('last_presence_source')
    expect(response.parsed_body.dig('payload', 'id')).to eq(sip_profile.id)
    expect(response.parsed_body.dig('payload', 'registered_for_routing')).to be(true)
    expect(response.parsed_body.dig('payload', 'calling_supported')).to be(true)
  end

  it 'records no-inbox browser registration presence on the only browser SIP profile' do
    sip_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: administrator,
      internal_extension: '505',
      agent_ref: 'local-profile-505',
      fonoster_agent_ref: 'remote-profile-505',
      agent_aor: 'sip:505@operator.cloud.vconsult.kz',
      availability_mode: 'browser_webphone'
    )

    post "/api/v1/accounts/#{account.id}/telephony/webphone/presence",
         params: { registered: true },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(sip_profile.reload.registered_for_routing?).to be(true)
    expect(response.parsed_body.dig('payload', 'id')).to eq(sip_profile.id)
    expect(response.parsed_body.dig('payload', 'registered_for_routing')).to be(true)
    expect(response.parsed_body.dig('payload', 'calling_supported')).to be(true)
  end

  it 'does not write browser presence to a hidden account binding for a managed inbox without a SIP profile' do
    legacy_binding = create(
      :telephony_agent_binding,
      account: account,
      user: administrator,
      provider: 'fonoster',
      agent_ref: 'legacy-agent-1001',
      agent_aor: 'sip:1001@operator.cloud.vconsult.kz'
    )
    voice_inbox.telephony_number_binding.update!(
      managed_by: Telephony::NumberBinding::MANAGED_BY_ONELINK,
      ownership_status: 'local'
    )

    post "/api/v1/accounts/#{account.id}/telephony/webphone/presence",
         params: { registered: true, inbox_id: voice_inbox.id },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(legacy_binding.reload.metadata).not_to include('last_presence_source')
    expect(legacy_binding.registered_for_routing?).to be(false)
    expect(response.parsed_body['payload']).to include(
      'provider' => 'fonoster',
      'calling_supported' => false,
      'registered' => false,
      'registered_for_routing' => false,
      'reason' => 'agent_binding_missing'
    )
  end

  it 'treats browser presence without an operator binding as a quiet unsupported state' do
    post "/api/v1/accounts/#{account.id}/telephony/webphone/presence",
         params: { registered: false },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['payload']).to include(
      'provider' => 'fonoster',
      'calling_supported' => false,
      'registered' => false,
      'registered_for_routing' => false,
      'reason' => 'agent_binding_missing'
    )
  end

  it 'does not advertise browser calling or call the bridge without an operator binding' do
    token_request = nil

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      token_request = stub_request(:post, 'https://bridge.example/telephony/webphone/token')

      post path, headers: headers, as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(token_request).not_to have_been_requested
    expect(response.parsed_body.dig('payload', 'provider')).to eq('fonoster')
    expect(response.parsed_body.dig('payload', 'calling_supported')).to be(false)
    expect(response.parsed_body.dig('payload', 'registered')).to be(false)
    expect(response.parsed_body.dig('payload', 'registered_for_routing')).to be(false)
    expect(response.parsed_body.dig('payload', 'reason')).to eq('agent_binding_missing')
  end

  it 'does not advertise browser calling or call the bridge for a disabled legacy binding' do
    create(
      :telephony_agent_binding,
      account: account,
      user: administrator,
      provider: 'fonoster',
      agent_ref: 'disabled-legacy-agent-1001',
      enabled: false
    )
    token_request = nil

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      token_request = stub_request(:post, 'https://bridge.example/telephony/webphone/token')

      post path, headers: headers, as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(token_request).not_to have_been_requested
    expect(response.parsed_body.dig('payload', 'calling_supported')).to be(false)
    expect(response.parsed_body.dig('payload', 'registered_for_routing')).to be(false)
    expect(response.parsed_body.dig('payload', 'reason')).to eq('agent_binding_missing')
  end

  it 'does not advertise browser calling for fonoster without a complete browser contract' do
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

  it 'returns structured claim details when the current operator browser is not registered' do
    agent_binding = create(
      :telephony_agent_binding,
      account: account,
      user: administrator,
      provider: 'fonoster',
      metadata: {
        registration_state: 'offline',
        registered: false,
        last_presence_event_at: Time.current.iso8601
      }
    )
    call_session = create(
      :telephony_call_session,
      account: account,
      external_call_ref: 'operator-pool-claim-unregistered',
      status: 'ringing',
      metadata: {
        'metadata' => {
          'route_action' => 'operator',
          'operator_candidate_user_ids' => [administrator.id],
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
    expect(response.parsed_body['details']).to include(
      'reason' => 'operator_not_registered',
      'agent_binding_id' => agent_binding.id,
      'registered_for_routing' => false,
      'registration_state' => 'offline'
    )
    expect(call_session.reload.agent_binding_id).to be_nil
  end

  it 'terminates an operator call when the browser phone cannot decline the SIP leg' do
    agent_binding = create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: administrator,
      provider: 'fonoster',
      agent_aor: 'sip:1001@operator.cloud.vconsult.kz'
    )
    call_session = create(
      :telephony_call_session,
      account: account,
      external_call_ref: 'operator-browser-reject-1',
      status: 'ringing',
      metadata: {
        'metadata' => {
          'route_action' => 'operator',
          'operator_candidate_user_ids' => [administrator.id],
          'operator_candidate_agent_refs' => [agent_binding.agent_ref]
        }
      }
    )

    bridge_seen_status = nil

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      terminate_request = stub_request(
        :post,
        'https://bridge.example/telephony/webphone/calls/operator-browser-reject-1/reject'
      ).with(
        body: hash_including(
          reason: 'operator_declined',
          agent_aor: 'sip:1001@operator.cloud.vconsult.kz',
          actor: 'operator'
        ),
        headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s }
      ).to_return do |_request|
        bridge_seen_status = call_session.reload.status
        { status: 202, body: { accepted: true }.to_json, headers: { 'Content-Type' => 'application/json' } }
      end

      post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
           params: { call_ref: call_session.external_call_ref, reason: 'operator_declined' },
           headers: headers,
           as: :json

      expect(terminate_request).to have_been_requested
    end

    expect(response).to have_http_status(:ok)
    expect(bridge_seen_status).to eq('rejected')
    expect(response.parsed_body.dig('payload', 'status')).to eq('rejected')
    expect(call_session.reload).to have_attributes(
      status: 'rejected',
      ended_by: "user:#{administrator.id}",
      end_reason: 'operator_declined'
    )
    expect(call_session.ended_at).to be_present
  end

  it 'terminates a Sipuni internal gateway target route without explicit candidate arrays' do
    create(:inbox_member, inbox: voice_inbox, user: administrator)
    profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: administrator,
      internal_extension: '504',
      availability_mode: 'browser_webphone',
      status: 'active',
      agent_ref: 'profile-local-504',
      fonoster_agent_ref: 'fonoster-profile-504',
      agent_aor: 'sip:504@operator.cloud.vconsult.kz',
      metadata: {
        registration_state: 'registered',
        presence: 'online',
        last_presence_event_at: Time.current.iso8601
      }
    )
    number_binding = Telephony::NumberBinding.find_by!(inbox_id: voice_inbox.id)
    call_session = create(
      :telephony_call_session,
      account: account,
      inbox: voice_inbox,
      conversation: create(:conversation, account: account, inbox: voice_inbox),
      number_binding: number_binding,
      external_call_ref: 'sipuni-target-reject-1',
      status: 'ringing',
      metadata: {
        'metadata' => {
          'source' => 'sipuni_internal_asterisk_gateway',
          'routeMode' => 'internal_asterisk_gateway',
          'target_extension' => '504',
          'onelink_user_id' => administrator.id,
          'telephony_sip_profile_id' => profile.id,
          'target_operator_agent_aor' => 'sip:504@operator.cloud.vconsult.kz'
        }
      }
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      terminate_request = stub_request(
        :post,
        'https://bridge.example/telephony/webphone/calls/sipuni-target-reject-1/reject'
      ).with(
        body: hash_including(
          reason: 'operator_declined',
          agent_aor: 'sip:504@operator.cloud.vconsult.kz',
          actor: 'operator'
        ),
        headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s }
      ).to_return(status: 202, body: { accepted: true }.to_json, headers: { 'Content-Type' => 'application/json' })

      post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
           params: { call_ref: call_session.external_call_ref, reason: 'operator_declined' },
           headers: headers,
           as: :json

      expect(terminate_request).to have_been_requested
    end

    expect(response).to have_http_status(:ok)
    expect(call_session.reload).to have_attributes(
      status: 'rejected',
      ended_by: "user:#{administrator.id}",
      end_reason: 'operator_declined'
    )
  end

  it 'hangs up a native Sipuni provider call through the Sipuni API when the operator releases it' do
    create(:inbox_member, inbox: voice_inbox, user: administrator)
    profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: administrator,
      internal_extension: '505',
      availability_mode: 'browser_webphone',
      status: 'active',
      agent_ref: 'sipuni-profile-505',
      agent_aor: 'sip:505@ats01.kz.sipuni.com',
      metadata: {
        registration_state: 'registered',
        presence: 'online',
        last_presence_event_at: Time.current.iso8601
      }
    )
    call_id = '1234567890.54321'
    call_session = create(
      :telephony_call_session,
      account: account,
      inbox: voice_inbox,
      conversation: create(:conversation, account: account, inbox: voice_inbox),
      number_binding: Telephony::NumberBinding.find_by!(inbox_id: voice_inbox.id),
      provider: 'sipuni',
      provider_call_sid: call_id,
      external_call_ref: "sipuni:#{call_id}",
      status: 'in_progress',
      direction: 'inbound',
      metadata: {
        'metadata' => {
          'route_action' => 'operator',
          'operator_candidate_sip_profile_ids' => [profile.id],
          'operator_candidate_user_ids' => [administrator.id],
          'operator_candidate_agent_refs' => [profile.agent_ref]
        },
        'operator_claim' => {
          'user_id' => administrator.id,
          'sip_profile_id' => profile.id
        }
      }
    )
    sipuni_user = '015856'
    sipuni_secret = 'sipuni-secret'
    expected_hash = Digest::MD5.hexdigest([call_id, sipuni_user, sipuni_secret].join('+'))

    with_modified_env(
      SIPUNI_INTEGRATION_USER: sipuni_user,
      SIPUNI_INTEGRATION_SECRET: sipuni_secret,
      SIPUNI_API_BASE_URL: 'https://sipuni.com'
    ) do
      hangup_request = stub_request(:post, 'https://sipuni.com/api/events/call/hangup')
                       .with(
                         body: hash_including(
                           'user' => sipuni_user,
                           'callId' => call_id,
                           'hash' => expected_hash
                         )
                       )
                       .to_return(status: 200, body: { success: true }.to_json, headers: { 'Content-Type' => 'application/json' })

      post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
           params: { call_ref: call_session.external_call_ref, status: 'completed', reason: 'operator_hangup' },
           headers: headers,
           as: :json

      expect(hangup_request).to have_been_requested
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('completed')
    expect(call_session.reload).to have_attributes(
      status: 'completed',
      ended_by: "user:#{administrator.id}",
      end_reason: 'operator_hangup'
    )
  end

  it 'still releases the local Sipuni call when the Sipuni hangup API fails' do
    create(:inbox_member, inbox: voice_inbox, user: administrator)
    profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: administrator,
      internal_extension: '506',
      availability_mode: 'browser_webphone',
      status: 'active',
      agent_ref: 'sipuni-profile-506',
      agent_aor: 'sip:506@ats01.kz.sipuni.com',
      metadata: {
        registration_state: 'registered',
        presence: 'online',
        last_presence_event_at: Time.current.iso8601
      }
    )
    call_id = '1234567890.54322'
    call_session = create(
      :telephony_call_session,
      account: account,
      inbox: voice_inbox,
      conversation: create(:conversation, account: account, inbox: voice_inbox),
      number_binding: Telephony::NumberBinding.find_by!(inbox_id: voice_inbox.id),
      provider: 'sipuni',
      provider_call_sid: call_id,
      external_call_ref: "sipuni:#{call_id}",
      status: 'ringing',
      direction: 'inbound',
      metadata: {
        'metadata' => {
          'route_action' => 'operator',
          'operator_candidate_sip_profile_ids' => [profile.id],
          'operator_candidate_user_ids' => [administrator.id],
          'operator_candidate_agent_refs' => [profile.agent_ref]
        }
      }
    )

    with_modified_env(
      SIPUNI_INTEGRATION_USER: '015856',
      SIPUNI_INTEGRATION_SECRET: 'sipuni-secret',
      SIPUNI_API_BASE_URL: 'https://sipuni.com'
    ) do
      stub_request(:post, 'https://sipuni.com/api/events/call/hangup')
        .to_return(status: 502, body: { error: 'sipuni unavailable' }.to_json, headers: { 'Content-Type' => 'application/json' })

      post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
           params: { call_ref: call_session.external_call_ref, status: 'rejected', reason: 'operator_declined' },
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('rejected')
    expect(call_session.reload).to have_attributes(
      status: 'rejected',
      ended_by: "user:#{administrator.id}",
      end_reason: 'operator_declined'
    )
    expect(call_session.metadata.dig('last_payload', 'metadata', 'sipuni_termination_error')).to eq('SIPUNI_REQUEST_FAILED')
  end

  it 'still releases the local operator call when bridge termination fails' do
    agent_binding = create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: administrator,
      provider: 'fonoster',
      agent_aor: 'sip:1001@operator.cloud.vconsult.kz'
    )
    call_session = create(
      :telephony_call_session,
      account: account,
      external_call_ref: 'operator-browser-reject-bridge-fails-1',
      status: 'ringing',
      metadata: {
        'metadata' => {
          'route_action' => 'operator',
          'operator_candidate_user_ids' => [administrator.id],
          'operator_candidate_agent_refs' => [agent_binding.agent_ref]
        }
      }
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(
        :post,
        'https://bridge.example/telephony/webphone/calls/operator-browser-reject-bridge-fails-1/reject'
      ).to_return(status: 502, body: { error: 'bridge unavailable' }.to_json, headers: { 'Content-Type' => 'application/json' })

      post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
           params: { call_ref: call_session.external_call_ref, reason: 'operator_declined' },
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('rejected')
    expect(call_session.reload).to have_attributes(
      status: 'rejected',
      ended_by: "user:#{administrator.id}",
      end_reason: 'operator_declined'
    )
    expect(call_session.metadata.dig('last_payload', 'metadata', 'bridge_termination_error')).to eq('BRIDGE_REQUEST_FAILED')
  end

  it 'marks an operator call as no-answer when claim succeeded but browser SIP had no pending call' do
    agent_binding = create(:telephony_agent_binding, :registered, account: account, user: administrator, provider: 'fonoster')
    call_session = create(
      :telephony_call_session,
      account: account,
      external_call_ref: 'operator-browser-no-answer-1',
      status: 'connecting',
      agent_binding: agent_binding,
      metadata: {
        'metadata' => {
          'route_action' => 'operator',
          'operator_candidate_user_ids' => [administrator.id]
        },
        'operator_claim' => {
          'user_id' => administrator.id,
          'agent_binding_id' => agent_binding.id
        }
      }
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      terminate_request = stub_request(
        :post,
        'https://bridge.example/telephony/webphone/calls/operator-browser-no-answer-1/reject'
      ).with(
        body: hash_including(
          reason: 'browser_webphone_not_ready',
          actor: 'operator'
        ),
        headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s }
      ).to_return(status: 202, body: { accepted: true }.to_json, headers: { 'Content-Type' => 'application/json' })

      post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
           params: { call_ref: call_session.external_call_ref, status: 'no_answer', reason: 'browser_webphone_not_ready' },
           headers: headers,
           as: :json

      expect(terminate_request).to have_been_requested
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('no_answer')
    expect(call_session.reload).to have_attributes(
      status: 'no_answer',
      ended_by: "user:#{administrator.id}",
      end_reason: 'browser_webphone_not_ready'
    )
  end

  it 'marks an active operator call as completed when the browser hangup releases it' do
    agent_binding = create(:telephony_agent_binding, :registered, account: account, user: administrator, provider: 'fonoster')
    call_session = create(
      :telephony_call_session,
      account: account,
      external_call_ref: 'operator-browser-hangup-1',
      status: 'in_progress',
      agent_binding: agent_binding,
      metadata: {
        'metadata' => {
          'route_action' => 'operator',
          'operator_candidate_user_ids' => [administrator.id]
        },
        'operator_claim' => {
          'user_id' => administrator.id,
          'agent_binding_id' => agent_binding.id
        }
      }
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      terminate_request = stub_request(
        :post,
        'https://bridge.example/telephony/webphone/calls/operator-browser-hangup-1/reject'
      ).with(
        body: hash_including(
          reason: 'operator_hangup',
          actor: 'operator'
        ),
        headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s }
      ).to_return(status: 202, body: { accepted: true }.to_json, headers: { 'Content-Type' => 'application/json' })

      post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
           params: { call_ref: call_session.external_call_ref, status: 'completed', reason: 'operator_hangup' },
           headers: headers,
           as: :json

      expect(terminate_request).to have_been_requested
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('completed')
    expect(call_session.reload).to have_attributes(
      status: 'completed',
      ended_by: "user:#{administrator.id}",
      end_reason: 'operator_hangup'
    )
  end

  it 'treats repeated browser hangup release for a completed operator call as idempotent' do
    agent_binding = create(:telephony_agent_binding, :registered, account: account, user: administrator, provider: 'fonoster')
    call_session = create(
      :telephony_call_session,
      account: account,
      external_call_ref: 'operator-browser-hangup-repeat-1',
      status: 'in_progress',
      agent_binding: agent_binding,
      metadata: {
        'metadata' => {
          'route_action' => 'operator',
          'operator_candidate_user_ids' => [administrator.id]
        },
        'operator_claim' => {
          'user_id' => administrator.id,
          'agent_binding_id' => agent_binding.id
        }
      }
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      terminate_request = stub_request(
        :post,
        'https://bridge.example/telephony/webphone/calls/operator-browser-hangup-repeat-1/reject'
      ).to_return(status: 202, body: { accepted: true }.to_json, headers: { 'Content-Type' => 'application/json' })

      post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
           params: { call_ref: call_session.external_call_ref, status: 'completed', reason: 'operator_hangup' },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(terminate_request).to have_been_requested.once

      post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
           params: { call_ref: call_session.external_call_ref, status: 'completed', reason: 'remote_hangup' },
           headers: headers,
           as: :json

      expect(terminate_request).to have_been_requested.once
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('completed')
    expect(call_session.reload).to have_attributes(
      status: 'completed',
      ended_by: "user:#{administrator.id}",
      end_reason: 'operator_hangup'
    )
  end

  it 'allows the current operator to hang up an outbound Fonoster operator-mode call' do
    agent_binding = create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: administrator,
      provider: 'fonoster',
      agent_ref: '1001',
      agent_aor: 'sip:1001@operator.cloud.vconsult.kz'
    )
    call_session = create(
      :telephony_call_session,
      account: account,
      external_call_ref: 'outbound-operator-mode-hangup-1',
      status: 'in_progress',
      direction: 'outbound',
      agent_binding: agent_binding,
      metadata: {
        'metadata' => {
          'mode' => 'operator',
          'routing_mode' => 'operator',
          'direction' => 'outbound',
          'call_direction' => 'outbound',
          'chatwoot_user_id' => administrator.id.to_s,
          'operator_agent_ref' => '1001',
          'operator_agent_aor' => 'sip:1001@operator.cloud.vconsult.kz'
        }
      }
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      terminate_request = stub_request(
        :post,
        'https://bridge.example/telephony/webphone/calls/outbound-operator-mode-hangup-1/reject'
      ).with(
        body: hash_including(
          reason: 'operator_hangup',
          agent_aor: 'sip:1001@operator.cloud.vconsult.kz',
          actor: 'operator'
        ),
        headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s }
      ).to_return(status: 202, body: { accepted: true }.to_json, headers: { 'Content-Type' => 'application/json' })

      post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
           params: { call_ref: call_session.external_call_ref, status: 'completed', reason: 'operator_hangup' },
           headers: headers,
           as: :json

      expect(terminate_request).to have_been_requested
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('completed')
    expect(call_session.reload).to have_attributes(
      status: 'completed',
      direction: 'outbound',
      ended_by: "user:#{administrator.id}",
      end_reason: 'operator_hangup'
    )
  end

  it 'allows an inbox member to cancel a pending outbound Fonoster call' do
    create(:inbox_member, inbox: voice_inbox, user: administrator)
    conversation = create(:conversation, account: account, inbox: voice_inbox)
    call_session = create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      contact: conversation.contact,
      inbox: voice_inbox,
      number_binding: voice_inbox.telephony_number_binding,
      external_call_ref: 'outbound-pending-cancel-1',
      status: 'created',
      direction: 'outbound',
      from_number: voice_channel.phone_number,
      to_number: conversation.contact.phone_number || '+15551230001',
      metadata: {
        'bridge_response' => { 'status' => 'created' },
        'fonoster_call_ref' => 'outbound-pending-cancel-1'
      }
    )
    message = conversation.messages.create!(
      account: account,
      inbox: voice_inbox,
      message_type: :outgoing,
      content_type: :voice_call,
      content: 'Voice Call',
      source_id: call_session.voice_call_source_id,
      content_attributes: {
        'data' => {
          'call_sid' => call_session.external_call_ref,
          'status' => 'created',
          'call_direction' => 'outbound'
        }
      }
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      terminate_request = stub_request(
        :post,
        'https://bridge.example/telephony/webphone/calls/outbound-pending-cancel-1/reject'
      ).with(
        body: hash_including(
          reason: 'operator_cancelled',
          actor: 'operator',
          call_direction: 'outbound'
        ),
        headers: { 'X-Bridge-Secret' => 'bridge-secret', 'X-Account-Id' => account.id.to_s }
      ).to_return(
        status: 202,
        body: { accepted: true }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

      post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
           params: {
             call_ref: call_session.external_call_ref,
             status: 'cancelled',
             reason: 'operator_cancelled'
           },
           headers: headers,
           as: :json

      expect(terminate_request).to have_been_requested
    end

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('payload', 'status')).to eq('cancelled')
      expect(call_session.reload).to have_attributes(
        status: 'cancelled',
        direction: 'outbound',
        ended_by: "user:#{administrator.id}",
        end_reason: 'operator_cancelled'
      )
      expect(message.reload.content_attributes.dig('data', 'status')).to eq(
        'cancelled'
      )
      expect(conversation.reload.additional_attributes).to include(
        'call_status' => 'cancelled',
        'call_direction' => 'outbound',
        'fonoster_call_ref' => call_session.external_call_ref
      )
    end
  end

  it 'rejects browser release attempts from unregistered operators before a claim' do
    agent_binding = create(:telephony_agent_binding, account: account, user: administrator, provider: 'fonoster')
    call_session = create(
      :telephony_call_session,
      account: account,
      external_call_ref: 'operator-browser-unregistered-1',
      status: 'ringing',
      metadata: {
        'metadata' => {
          'route_action' => 'operator',
          'operator_candidate_user_ids' => [administrator.id],
          'operator_candidate_agent_refs' => [agent_binding.agent_ref]
        }
      }
    )

    post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
         params: { call_ref: call_session.external_call_ref, reason: 'operator_rejected_from_browser' },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['code']).to eq('OPERATOR_NOT_CANDIDATE')
    expect(call_session.reload.status).to eq('ringing')
  end

  it 'does not let a second operator release a call claimed by someone else' do
    winner = create(:telephony_agent_binding, :registered, account: account, user: administrator, provider: 'fonoster')
    loser_user = create(:user, account: account, role: :agent)
    loser_headers = loser_user.create_new_auth_token
    loser = create(:telephony_agent_binding, :registered, account: account, user: loser_user, provider: 'fonoster')
    call_session = create(
      :telephony_call_session,
      account: account,
      external_call_ref: 'operator-browser-claimed-other-1',
      status: 'connecting',
      agent_binding: winner,
      metadata: {
        'metadata' => {
          'route_action' => 'operator',
          'operator_candidate_user_ids' => [administrator.id, loser_user.id],
          'operator_candidate_agent_refs' => [winner.agent_ref, loser.agent_ref]
        },
        'operator_claim' => {
          'user_id' => administrator.id,
          'agent_binding_id' => winner.id
        }
      }
    )

    post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
         params: { call_ref: call_session.external_call_ref, status: 'no_answer', reason: 'browser_webphone_not_ready' },
         headers: loser_headers,
         as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('CALL_ALREADY_CLAIMED')
    expect(call_session.reload.status).to eq('connecting')
  end

  it 'does not let stale operator claim metadata override a different claimed binding' do
    winner = create(:telephony_agent_binding, :registered, account: account, user: administrator, provider: 'fonoster')
    stale_metadata_user = create(:user, account: account, role: :agent)
    stale_headers = stale_metadata_user.create_new_auth_token
    stale_binding = create(:telephony_agent_binding, :registered, account: account, user: stale_metadata_user, provider: 'fonoster')
    call_session = create(
      :telephony_call_session,
      account: account,
      external_call_ref: 'operator-browser-stale-claim-1',
      status: 'connecting',
      agent_binding: winner,
      metadata: {
        'metadata' => {
          'route_action' => 'operator',
          'operator_candidate_user_ids' => [administrator.id, stale_metadata_user.id],
          'operator_candidate_agent_refs' => [winner.agent_ref, stale_binding.agent_ref]
        },
        'operator_claim' => {
          'user_id' => stale_metadata_user.id,
          'agent_binding_id' => stale_binding.id
        }
      }
    )

    post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
         params: { call_ref: call_session.external_call_ref, status: 'no_answer', reason: 'browser_webphone_not_ready' },
         headers: stale_headers,
         as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('CALL_ALREADY_CLAIMED')
    expect(call_session.reload.status).to eq('connecting')
  end

  def unsigned_jwt(claims)
    header = Base64.urlsafe_encode64({ alg: 'none', typ: 'JWT' }.to_json, padding: false)
    payload = Base64.urlsafe_encode64(claims.to_json, padding: false)
    "#{header}.#{payload}.signature"
  end
end
