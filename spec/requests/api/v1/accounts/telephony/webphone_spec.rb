require 'rails_helper'

RSpec.describe 'Telephony Webphone API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:voice_phone_number) { "+1555#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}" }
  let(:voice_channel) { create(:channel_voice, :sipuni, account: account, phone_number: voice_phone_number) }
  let(:voice_inbox) { voice_channel.inbox }
  let(:path) { "/api/v1/accounts/#{account.id}/telephony/webphone/token" }

  before do
    account.enable_features!('channel_voice')
  end

  def sip_presence_params(profile, overrides = {})
    {
      sip_profile_id: profile.id,
      account_id: profile.account_id,
      inbox_id: profile.inbox_id,
      internal_extension: profile.internal_extension,
      sip_username: profile.sip_username,
      sip_host: profile.sip_host,
      agent_aor: profile.agent_aor,
      registration_config_version: profile.registration_config_version,
      registration_instance_id: "registration-#{profile.id}",
      janus_session_id: "janus-session-#{profile.id}",
      janus_handle_id: "janus-handle-#{profile.id}",
      session_key: "sip_profile:#{profile.id}"
    }.merge(overrides)
  end

  def mark_sip_profile_registered!(profile)
    profile.update_browser_registration!(registered: true, registration_context: sip_presence_params(profile))
  end

  def expect_janus_server_recording(payload, provider)
    expect(payload).to include(
      'provider' => provider,
      'recording_strategy' => 'janus_server',
      'recording_fallback_strategy' => 'browser_fallback'
    )
    expect(payload['janus_recording']).to include('audio' => true, 'peer_audio' => true, 'layout' => 'dual_channel')
  end

  def expect_authorized_janus_url(url, server_url:, profile:)
    uri = URI.parse(url)
    ticket = URI.decode_www_form(uri.query.to_s).to_h.fetch('janus_ticket')

    expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq(server_url)
    expect(
      Telephony::JanusWebsocketTicket.valid?(
        ticket: ticket,
        origin: "https://#{uri.host}",
        path: uri.path
      )
    ).to be(true)
    expect(profile.reload).to be_enabled
  end

  it 'returns an unsupported payload instead of raising for non-voice inboxes' do
    instagram_inbox = create(:channel_instagram, account: account).inbox

    post path,
         params: { inbox_id: instagram_inbox.id },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['payload']).to include(
      'provider' => nil,
      'calling_supported' => false,
      'registered' => false,
      'registered_for_routing' => false,
      'reason' => 'agent_binding_missing'
    )
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
        sipuni_events_webhook_token: 'sipuni-webhook-token',
        routing_mode: 'operator',
        operator_distribution_mode: 'broadcast'
      }
    )
    sipuni_inbox = sipuni_channel.inbox
    create(:inbox_member, inbox: sipuni_inbox, user: administrator)
    sip_profile = create(
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
      availability_mode: 'browser_webphone',
      status: 'active',
      agent_aor: 'sip:990001000021@ats01.kz.sipuni.com'
    )
    mark_sip_profile_registered!(sip_profile)

    with_modified_env(
      TELEPHONY_SIPUNI_JANUS_WS_URL: 'wss://dev.one-link.kz/janus-sipuni',
      TELEPHONY_JANUS_WS_URL: 'wss://dev.one-link.kz/janus-sipuni',
      TELEPHONY_JANUS_SERVER_RECORDING_ENABLED: 'false',
      TELEPHONY_SIPUNI_JANUS_SERVER_RECORDING_ENABLED: 'false',
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
    expect_authorized_janus_url(
      payload['janus_server'],
      server_url: 'wss://dev.one-link.kz/janus-sipuni',
      profile: sip_profile
    )
    expect(payload['janusServer']).to eq(payload['janus_server'])
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
    expect(payload['recording_strategy']).to eq('provider_api')
    expect(payload['recording_fallback_strategy']).to eq('browser_fallback')
  end

  it 'falls back to browser recording for native Sipuni browser profiles without webhook/API recording' do
    provider_connection = create(
      :telephony_provider_connection,
      account: account,
      provider_kind: 'sipuni',
      host: 'ats01.kz.sipuni.com',
      port: 5060,
      transport: 'udp',
      username: '990001000022'
    )
    sipuni_channel = create(
      :channel_voice,
      account: account,
      provider: 'sipuni',
      phone_number: '+15551232000',
      provider_config: {
        provider_kind: 'sipuni',
        provider_connection_id: provider_connection.id,
        number_ref: 'sipuni-browser-number-no-webhook',
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
      internal_extension: '502',
      provider_connection: provider_connection,
      sip_username: '990001000022',
      sip_password: 'test-sip-password',
      availability_mode: 'browser_webphone',
      status: 'active',
      agent_aor: 'sip:990001000022@ats01.kz.sipuni.com'
    )

    with_modified_env(
      TELEPHONY_SIPUNI_JANUS_WS_URL: 'wss://dev.one-link.kz/janus-sipuni',
      TELEPHONY_JANUS_WS_URL: 'wss://dev.one-link.kz/janus-sipuni',
      TELEPHONY_JANUS_SERVER_RECORDING_ENABLED: 'false',
      TELEPHONY_SIPUNI_JANUS_SERVER_RECORDING_ENABLED: 'false',
      SIPUNI_WEBHOOK_TOKEN: nil,
      TELEPHONY_SIPUNI_WEBHOOK_TOKEN: nil,
      SIPUNI_INTEGRATION_USER: nil,
      SIPUNI_INTEGRATION_SECRET: nil
    ) do
      post path,
           params: { inbox_id: sipuni_inbox.id },
           headers: headers,
           as: :json
    end

    payload = response.parsed_body.fetch('payload')
    expect(response).to have_http_status(:ok)
    expect(payload['provider']).to eq('sipuni')
    expect(payload['recording_strategy']).to eq('browser_fallback')
    expect(payload['recording_fallback_strategy']).to be_nil
  end

  it 'returns a Janus SIP webphone contract for native Binotel browser profiles' do
    provider_connection = create(
      :telephony_provider_connection,
      account: account,
      provider_kind: 'binotel',
      host: 'sip53.binotel.com',
      port: 5060,
      transport: 'udp',
      username: 'pq4dyw5f'
    )
    binotel_channel = create(
      :channel_voice,
      account: account,
      provider: 'binotel',
      phone_number: '+15550001755',
      provider_config: {
        provider_kind: 'binotel',
        provider_connection_id: provider_connection.id,
        number_ref: 'binotel-browser-number-ref',
        routing_mode: 'operator',
        operator_distribution_mode: 'broadcast'
      }
    )
    binotel_inbox = binotel_channel.inbox
    create(:inbox_member, inbox: binotel_inbox, user: administrator)
    sip_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: binotel_inbox,
      user: administrator,
      internal_extension: '901',
      provider_connection: provider_connection,
      sip_username: 'pq4dyw5f',
      sip_password: 'test-binotel-password',
      agent_ref: 'local-binotel-profile-901',
      availability_mode: 'browser_webphone',
      status: 'active',
      agent_aor: 'sip:pq4dyw5f@sip53.binotel.com'
    )
    mark_sip_profile_registered!(sip_profile)

    with_modified_env(
      TELEPHONY_BINOTEL_JANUS_WS_URL: 'wss://dev.one-link.kz/janus-sipuni',
      TELEPHONY_JANUS_SERVER_RECORDING_ENABLED: 'false',
      TELEPHONY_BINOTEL_JANUS_SERVER_RECORDING_ENABLED: 'false'
    ) do
      post path,
           params: { inbox_id: binotel_inbox.id },
           headers: headers,
           as: :json
    end

    payload = response.parsed_body.fetch('payload')
    expect(response).to have_http_status(:ok)
    expect(payload['provider']).to eq('binotel')
    expect_authorized_janus_url(
      payload['janus_server'],
      server_url: 'wss://dev.one-link.kz/janus-sipuni',
      profile: sip_profile
    )
    expect(payload['janusServer']).to eq(payload['janus_server'])
    expect(payload['sip']).to include(
      'username' => 'pq4dyw5f',
      'auth_username' => 'pq4dyw5f',
      'password' => 'test-binotel-password',
      'host' => 'sip53.binotel.com',
      'port' => 5060,
      'transport' => 'udp',
      'uri' => 'sip:pq4dyw5f@sip53.binotel.com',
      'proxy' => 'sip:sip53.binotel.com:5060',
      'internal_extension' => '901'
    )
    expect(payload['calling_supported']).to be(true)
    expect(payload['registered_for_routing']).to be(true)
    expect(payload['recording_strategy']).to eq('browser_fallback')
  end

  it 'uses Janus server recording with a browser safety fallback when enabled' do
    sipuni_profile, binotel_profile, asterisk_profile = create_native_janus_browser_profiles

    with_modified_env(
      TELEPHONY_ASTERISK_ANALOG_JANUS_WS_URL: 'wss://dev.one-link.kz/janus-sipuni',
      TELEPHONY_SIPUNI_JANUS_WS_URL: 'wss://dev.one-link.kz/janus-sipuni',
      TELEPHONY_BINOTEL_JANUS_WS_URL: 'wss://dev.one-link.kz/janus-sipuni',
      TELEPHONY_JANUS_WS_URL: 'wss://dev.one-link.kz/janus-sipuni',
      TELEPHONY_JANUS_SERVER_RECORDING_ENABLED: 'true',
      TELEPHONY_SIPUNI_JANUS_SERVER_RECORDING_ENABLED: 'true',
      TELEPHONY_BINOTEL_JANUS_SERVER_RECORDING_ENABLED: 'true',
      TELEPHONY_ASTERISK_ANALOG_JANUS_SERVER_RECORDING_ENABLED: 'true',
      TELEPHONY_JANUS_RECORDING_FILENAME_PREFIX: 'janus-prod'
    ) do
      post path,
           params: { inbox_id: asterisk_profile.inbox_id },
           headers: headers,
           as: :json

      payload = response.parsed_body.fetch('payload')
      expect(response).to have_http_status(:ok)
      expect_janus_server_recording(payload, 'asterisk_analog')

      post path,
           params: { inbox_id: sipuni_profile.inbox_id },
           headers: headers,
           as: :json

      sipuni_payload = response.parsed_body.fetch('payload')
      expect_janus_server_recording(sipuni_payload, 'sipuni')

      post path,
           params: { inbox_id: binotel_profile.inbox_id },
           headers: headers,
           as: :json

      binotel_payload = response.parsed_body.fetch('payload')
      expect_janus_server_recording(binotel_payload, 'binotel')
    end
  end

  it 'returns provider-specific outbound dialing settings for native Janus SIP profiles' do
    _sipuni_profile, _binotel_profile, asterisk_profile = create_native_janus_browser_profiles
    asterisk_profile.provider_connection.update!(metadata: { outbound_dial_format: 'kz_trunk' })

    with_modified_env(
      TELEPHONY_ASTERISK_ANALOG_JANUS_WS_URL: 'wss://dev.one-link.kz/janus-asterisk'
    ) do
      post path,
           params: { inbox_id: asterisk_profile.inbox_id },
           headers: headers,
           as: :json
    end

    payload = response.parsed_body.fetch('payload')
    expect(response).to have_http_status(:ok)
    expect(payload['provider']).to eq('asterisk_analog')
    expect(payload.dig('sip', 'outbound_dial_format')).to eq('kz_trunk')
    expect(payload.dig('sip', 'outboundDialFormat')).to eq('kz_trunk')
    expect(payload['outbound_dial_format']).to eq('kz_trunk')
    expect(payload['outboundDialFormat']).to eq('kz_trunk')
  end

  it 'returns all native Janus SIP browser profiles for no-inbox bootstrap' do
    profiles = create_native_janus_browser_profiles

    with_modified_env(
      TELEPHONY_ASTERISK_ANALOG_JANUS_WS_URL: 'wss://dev.one-link.kz/janus-sipuni',
      TELEPHONY_SIPUNI_JANUS_WS_URL: 'wss://dev.one-link.kz/janus-sipuni',
      TELEPHONY_BINOTEL_JANUS_WS_URL: 'wss://dev.one-link.kz/janus-sipuni',
      TELEPHONY_JANUS_WS_URL: 'wss://dev.one-link.kz/janus-sipuni',
      TELEPHONY_JANUS_SERVER_RECORDING_ENABLED: 'false',
      TELEPHONY_SIPUNI_JANUS_SERVER_RECORDING_ENABLED: 'false',
      TELEPHONY_BINOTEL_JANUS_SERVER_RECORDING_ENABLED: 'false',
      TELEPHONY_ASTERISK_ANALOG_JANUS_SERVER_RECORDING_ENABLED: 'false',
      SIPUNI_WEBHOOK_TOKEN: nil,
      TELEPHONY_SIPUNI_WEBHOOK_TOKEN: nil
    ) do
      post path, headers: headers, as: :json
    end

    payload = response.parsed_body.fetch('payload')
    sessions = payload.fetch('sessions')
    expect(response).to have_http_status(:ok)
    expect(payload['multi_session']).to be(true)
    expect(sessions.pluck('provider')).to match_array(%w[sipuni binotel asterisk_analog])
    expect(sessions.pluck('sip_profile_id')).to match_array(profiles.map(&:id))
    expect(sessions.map { |session| session.dig('sip', 'username') }).to match_array(profiles.map(&:sip_username))
    sessions.each do |session|
      expect_authorized_janus_url(
        session.fetch('janus_server'),
        server_url: 'wss://dev.one-link.kz/janus-sipuni',
        profile: profiles.find { |profile| profile.id == session.fetch('sip_profile_id') }
      )
    end
    recording_strategies =
      sessions.index_by { |session| session['provider'] }
              .transform_values { |session| session['recording_strategy'] }
    expect(recording_strategies).to include(
      'sipuni' => 'browser_fallback',
      'binotel' => 'browser_fallback',
      'asterisk_analog' => 'browser_fallback'
    )
  end

  it 'creates an operator call session from a native Janus SIP incoming event' do
    _sipuni_profile, binotel_profile, _asterisk_profile = create_native_janus_browser_profiles
    incoming_path = "/api/v1/accounts/#{account.id}/telephony/webphone/incoming"
    raw_call_ref = 'janus-binotel-incoming-1'
    expected_call_ref = "binotel:janus:#{binotel_profile.id}:#{raw_call_ref}"

    post incoming_path,
         params: {
           inbox_id: binotel_profile.inbox_id,
           provider: 'binotel',
           call_ref: raw_call_ref,
           from: 'sip:+77475318623@sip53.binotel.com',
           session_key: "sip_profile:#{binotel_profile.id}",
           sip_profile_id: binotel_profile.id,
           internal_extension: binotel_profile.internal_extension
         }.merge(sip_presence_params(binotel_profile)),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    call_session = account.telephony_call_sessions.find_by!(external_call_ref: expected_call_ref)
    route_metadata = call_session.metadata.fetch('metadata')

    expect(payload).to include(
      'call_sid' => expected_call_ref,
      'callSid' => expected_call_ref,
      'provider' => 'binotel',
      'status' => 'ringing',
      'direction' => 'inbound',
      'inbox_id' => binotel_profile.inbox_id,
      'from_number' => '+77475318623',
      'operator_internal_extension' => binotel_profile.internal_extension,
      'sip_profile_id' => binotel_profile.id,
      'browser_join_supported' => true,
      'route_action' => 'operator'
    )
    expect(call_session).to have_attributes(
      account_id: account.id,
      inbox_id: binotel_profile.inbox_id,
      provider: 'binotel',
      status: 'ringing',
      direction: 'inbound',
      from_number: '+77475318623'
    )
    expect(route_metadata).to include(
      'source' => 'browser_janus_sip',
      'registration_instance_id' => "registration-#{binotel_profile.id}",
      'registration_config_version' => binotel_profile.registration_config_version,
      'target_sip_profile_id' => binotel_profile.id,
      'target_user_id' => administrator.id,
      'operator_candidate_sip_profile_ids' => include(binotel_profile.id),
      'operator_candidate_user_ids' => include(administrator.id)
    )
    expect(binotel_profile.reload.registered_for_routing?).to be(true)
  end

  it 'accepts a legacy incoming event missing only the registration instance from the active browser lease' do
    _sipuni_profile, binotel_profile, _asterisk_profile = create_native_janus_browser_profiles
    mark_sip_profile_registered!(binotel_profile)
    raw_call_ref = 'legacy-janus-binotel-incoming'

    post "/api/v1/accounts/#{account.id}/telephony/webphone/incoming",
         params: {
           inbox_id: binotel_profile.inbox_id,
           provider: 'binotel',
           call_ref: raw_call_ref,
           from: 'sip:+774****0001@sip53.binotel.com',
           session_key: "sip_profile:#{binotel_profile.id}",
           internal_extension: binotel_profile.internal_extension
         }.merge(sip_presence_params(binotel_profile).except(:registration_instance_id)),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    call_session = account.telephony_call_sessions.find_by!('external_call_ref LIKE ?', "%#{raw_call_ref}%")
    expect(call_session.metadata.dig('metadata', 'registration_instance_id')).to eq("registration-#{binotel_profile.id}")
  end

  it 'rejects a legacy incoming event when its Janus session does not match the active browser lease' do
    _sipuni_profile, binotel_profile, _asterisk_profile = create_native_janus_browser_profiles
    mark_sip_profile_registered!(binotel_profile)
    raw_call_ref = 'legacy-stale-janus-binotel-incoming'

    post "/api/v1/accounts/#{account.id}/telephony/webphone/incoming",
         params: {
           inbox_id: binotel_profile.inbox_id,
           provider: 'binotel',
           call_ref: raw_call_ref,
           from: 'sip:+774****0002@sip53.binotel.com',
           session_key: "sip_profile:#{binotel_profile.id}",
           internal_extension: binotel_profile.internal_extension
         }.merge(
           sip_presence_params(binotel_profile).except(:registration_instance_id).merge(
             janus_session_id: 'stale-janus-session'
           )
         ),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('WEBPHONE_SIP_REGISTRATION_CONTEXT_INCOMPLETE')
    expect(account.telephony_call_sessions.where('external_call_ref LIKE ?', "%#{raw_call_ref}%")).to be_empty
  end

  it 'rejects a stale native Janus incoming event without replacing the active browser lease' do
    _sipuni_profile, binotel_profile, _asterisk_profile = create_native_janus_browser_profiles
    mark_sip_profile_registered!(binotel_profile)
    active_context = binotel_profile.reload.metadata.fetch('registration_context')

    post "/api/v1/accounts/#{account.id}/telephony/webphone/incoming",
         params: {
           inbox_id: binotel_profile.inbox_id,
           provider: 'binotel',
           call_ref: 'stale-janus-binotel-incoming',
           from: 'sip:+77470000000@sip53.binotel.com',
           session_key: "sip_profile:#{binotel_profile.id}",
           sip_profile_id: binotel_profile.id,
           internal_extension: binotel_profile.internal_extension
         }.merge(
           sip_presence_params(
             binotel_profile,
             registration_instance_id: 'stale-registration-instance',
             janus_session_id: 'stale-janus-session',
             janus_handle_id: 'stale-janus-handle'
           )
         ),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('WEBPHONE_SIP_REGISTRATION_LEASE_CONFLICT')
    expect(account.telephony_call_sessions.where('external_call_ref LIKE ?', '%stale-janus-binotel-incoming%')).to be_empty
    expect(binotel_profile.reload.metadata.fetch('registration_context')).to eq(active_context)
  end

  it 'rejects native Janus incoming events missing any required registration identifier' do
    _sipuni_profile, binotel_profile, _asterisk_profile = create_native_janus_browser_profiles

    %i[
      sip_profile_id
      registration_config_version
      registration_instance_id
      janus_session_id
      janus_handle_id
    ].each do |missing_key|
      call_ref = "incomplete-janus-binotel-incoming-#{missing_key}"
      params = {
        inbox_id: binotel_profile.inbox_id,
        provider: 'binotel',
        call_ref: call_ref,
        from: 'sip:+774****0000@sip53.binotel.com',
        session_key: "sip_profile:#{binotel_profile.id}",
        sip_profile_id: binotel_profile.id,
        internal_extension: binotel_profile.internal_extension
      }.merge(sip_presence_params(binotel_profile)).except(missing_key)

      post "/api/v1/accounts/#{account.id}/telephony/webphone/incoming",
           params: params,
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['code']).to eq('WEBPHONE_SIP_REGISTRATION_CONTEXT_INCOMPLETE')
      expect(account.telephony_call_sessions.find_by(external_call_ref: call_ref)).to be_nil
    end
  end

  it 'creates a Sipuni operator call session from native Janus SIP incoming without requiring the webhook' do
    sipuni_profile, _binotel_profile, _asterisk_profile = create_native_janus_browser_profiles
    incoming_path = "/api/v1/accounts/#{account.id}/telephony/webphone/incoming"
    raw_call_ref = 'raw-sipuni-native-no-webhook@91.215.136.2:8217'
    expected_call_ref = "sipuni:janus:#{sipuni_profile.id}:#{raw_call_ref}"

    with_modified_env(
      SIPUNI_WEBHOOK_TOKEN: nil,
      TELEPHONY_SIPUNI_WEBHOOK_TOKEN: nil
    ) do
      post incoming_path,
           params: {
             inbox_id: sipuni_profile.inbox_id,
             provider: 'sipuni',
             call_ref: raw_call_ref,
             from: 'sip:+15555550123@91.215.136.2:8217',
             session_key: "sip_profile:#{sipuni_profile.id}",
             sip_profile_id: sipuni_profile.id,
             internal_extension: sipuni_profile.internal_extension
           }.merge(sip_presence_params(sipuni_profile)),
           headers: headers,
           as: :json
    end

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    call_session = account.telephony_call_sessions.find_by!(external_call_ref: expected_call_ref)
    route_metadata = call_session.metadata.fetch('metadata')

    expect(payload).to include(
      'call_sid' => expected_call_ref,
      'callSid' => expected_call_ref,
      'provider' => 'sipuni',
      'status' => 'ringing',
      'direction' => 'inbound',
      'inbox_id' => sipuni_profile.inbox_id,
      'sip_profile_id' => sipuni_profile.id,
      'browser_join_supported' => true,
      'route_action' => 'operator'
    )
    expect(account.telephony_call_sessions.where(provider: 'sipuni').count).to eq(1)
    expect(route_metadata).to include(
      'source' => 'browser_janus_sip',
      'target_sip_profile_id' => sipuni_profile.id,
      'target_user_id' => administrator.id,
      'operator_candidate_sip_profile_ids' => include(sipuni_profile.id),
      'operator_candidate_user_ids' => include(administrator.id)
    )
  end

  it 'attaches a pending native Janus SIP incoming call to AI voice without creating an operator route' do
    sipuni_profile, _binotel_profile, _asterisk_profile = create_native_janus_browser_profiles
    voice_agent_profile = create(
      :telephony_sip_profile,
      :voice_agent,
      account: account,
      inbox: sipuni_profile.inbox,
      provider_connection: sipuni_profile.provider_connection,
      internal_extension: '9098',
      sip_username: 'ai-agent-9098',
      availability_mode: 'browser_webphone',
      status: 'active'
    )
    incoming_path = "/api/v1/accounts/#{account.id}/telephony/webphone/incoming"
    raw_call_ref = 'raw-sipuni-ai-pending@91.215.136.2:8217'
    expected_call_ref = "sipuni:janus:#{voice_agent_profile.id}:#{raw_call_ref}"
    binding = Telephony::NumberBinding.sync_from_voice_channel!(sipuni_profile.inbox.channel)
    assistant = create(:captain_assistant, account: account)
    binding.routing_policy.update!(
      mode: 'operator',
      ai_enabled: true,
      ai_deployment_mode: 'onelink_managed',
      onelink_ai_app_ref: 'onelink-managed-voice-agent',
      captain_assistant: assistant
    )
    contact = create(:contact, account: account, phone_number: '+77475318623')
    contact_inbox = create(:contact_inbox, contact: contact, inbox: sipuni_profile.inbox, source_id: '+77475318623')
    conversation = create(
      :conversation,
      account: account,
      inbox: sipuni_profile.inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: 'pending'
    )

    with_modified_env(
      ONELINK_AI_VOICE_BASE_URL: 'http://voice.internal:8083',
      ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret'
    ) do
      runtime_stub = stub_request(:post, 'http://voice.internal:8083/internal/janus-sip/calls')
                     .with(headers: { 'Authorization' => 'Bearer voice-secret', 'Content-Type' => 'application/json' }) do |request|
                       body = JSON.parse(request.body)
                       expect(body).to include(
                         'call_ref' => expected_call_ref,
                         'bridge_call_ref' => expected_call_ref,
                         'account_id' => account.id.to_s,
                         'inbox_id' => sipuni_profile.inbox_id.to_s,
                         'conversation_id' => conversation.id.to_s,
                         'provider' => 'sipuni',
                         'transport' => 'janus_sip',
                         'sip_profile_id' => voice_agent_profile.id.to_s
                       )
                       expect(body['sip_profile']).to include(
                         'id' => voice_agent_profile.id,
                         'profile_kind' => 'voice_agent',
                         'voice_agent' => true,
                         'internal_extension' => '9098',
                         'sip_username' => 'ai-agent-9098'
                       )
                       expect(body.to_json).not_to include('voice-agent-secret')
                       expect(body['routing']).to include(
                         'action' => 'ai',
                         'reason' => 'pending_conversation_ai_route',
                         'conversation_status' => 'pending',
                         'captain_assistant_id' => assistant.id
                       )
                       expect(body.dig('routing', 'ai_context')).to include(
                         'call_ref' => expected_call_ref,
                         'account_id' => account.id,
                         'conversation_id' => conversation.id,
                         'number_ref' => binding.number_ref
                       )
                       expect(body.dig('routing', 'ai_context', 'tools').pluck('name')).to include('faq_lookup')
                       expect(body['ai_context']).to eq(body.dig('routing', 'ai_context'))
                       expect(body['janus']).to include(
                         'session_id' => 'janus-session-1',
                         'handle_id' => 'janus-handle-1',
                         'unique_id' => 'janus-unique-1',
                         'master_id' => 'janus-master-1'
                       )
                     end
                     .to_return(
                       status: 202,
                       body: { status: 'accepted', mode: 'accepted', call_ref: expected_call_ref, transport: 'janus_sip' }.to_json,
                       headers: { 'Content-Type' => 'application/json' }
                     )

      post incoming_path,
           params: {
             inbox_id: sipuni_profile.inbox_id,
             provider: 'sipuni',
             call_ref: raw_call_ref,
             from: 'sip:+77475318623@91.215.136.2:8217',
             session_key: "sip_profile:#{voice_agent_profile.id}",
             sip_profile_id: voice_agent_profile.id,
             janus_session_id: 'janus-session-1',
             janus_handle_id: 'janus-handle-1',
             janus_unique_id: 'janus-unique-1',
             janus_master_id: 'janus-master-1',
             internal_extension: voice_agent_profile.internal_extension
           }.merge(
             sip_presence_params(
               voice_agent_profile,
               janus_session_id: 'janus-session-1',
               janus_handle_id: 'janus-handle-1'
             )
           ),
           headers: headers,
           as: :json

      expect(runtime_stub).to have_been_requested
    end

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    call_session = account.telephony_call_sessions.find_by!(external_call_ref: expected_call_ref)
    expect(payload).to include(
      'call_sid' => expected_call_ref,
      'provider' => 'sipuni',
      'route_action' => 'ai'
    )
    expect(payload['sip_profile_id']).to eq(voice_agent_profile.id)
    expect(payload['ai_voice']).to include(
      'state' => 'attached',
      'transport' => 'janus_sip',
      'provider' => 'sipuni'
    )
    expect(call_session).to have_attributes(
      conversation_id: conversation.id,
      contact_id: contact.id,
      status: 'ringing',
      direction: 'inbound'
    )
    expect(call_session.metadata.dig('metadata', 'route_action')).to eq('ai')
    expect(call_session.metadata.dig('metadata', 'voice_agent')).to be(true)
    expect(call_session.metadata.dig('metadata', 'voice_agent_sip_profile_id')).to eq(voice_agent_profile.id)
    expect(call_session.metadata.dig('metadata', 'janus_unique_id')).to eq('janus-unique-1')
    expect(call_session.metadata.dig('ai_voice', 'state')).to eq('attached')
  end

  it 'rejects a native Janus SIP AI route when the explicit SIP profile is not a voice agent' do
    sipuni_profile, _binotel_profile, _asterisk_profile = create_native_janus_browser_profiles
    incoming_path = "/api/v1/accounts/#{account.id}/telephony/webphone/incoming"
    binding = Telephony::NumberBinding.sync_from_voice_channel!(sipuni_profile.inbox.channel)
    assistant = create(:captain_assistant, account: account)
    binding.routing_policy.update!(
      mode: 'operator',
      ai_enabled: true,
      ai_deployment_mode: 'onelink_managed',
      onelink_ai_app_ref: 'onelink-managed-voice-agent',
      captain_assistant: assistant
    )
    create(
      :telephony_sip_profile,
      :voice_agent,
      account: account,
      inbox: sipuni_profile.inbox,
      provider_connection: sipuni_profile.provider_connection,
      internal_extension: '9099',
      sip_username: 'ai-agent-9099',
      availability_mode: 'browser_webphone',
      status: 'active'
    )
    contact = create(:contact, account: account, phone_number: '+77475318624')
    contact_inbox = create(:contact_inbox, contact: contact, inbox: sipuni_profile.inbox, source_id: '+77475318624')
    create(
      :conversation,
      account: account,
      inbox: sipuni_profile.inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: 'pending'
    )

    with_modified_env(
      ONELINK_AI_VOICE_BASE_URL: 'http://voice.internal:8083',
      ONELINK_AI_VOICE_INTERNAL_TOKEN: 'voice-secret'
    ) do
      runtime_stub = stub_request(:post, 'http://voice.internal:8083/internal/janus-sip/calls')

      post incoming_path,
           params: {
             inbox_id: sipuni_profile.inbox_id,
             provider: 'sipuni',
             call_ref: 'raw-sipuni-ai-no-profile@91.215.136.2:8217',
             from: 'sip:+77475318624@91.215.136.2:8217',
             session_key: "sip_profile:#{sipuni_profile.id}",
             sip_profile_id: sipuni_profile.id,
             janus_session_id: 'janus-session-2',
             janus_handle_id: 'janus-handle-2',
             janus_unique_id: 'janus-unique-2',
             janus_master_id: 'janus-master-2',
             internal_extension: sipuni_profile.internal_extension
           }.merge(sip_presence_params(sipuni_profile)),
           headers: headers,
           as: :json

      expect(runtime_stub).not_to have_been_requested
    end

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    call_session = account.telephony_call_sessions.find_by!(
      external_call_ref: "sipuni:janus:#{sipuni_profile.id}:raw-sipuni-ai-no-profile@91.215.136.2:8217"
    )
    expect(payload).to include(
      'route_action' => 'reject',
      'browser_join_supported' => true
    )
    expect(call_session.metadata.dig('metadata', 'route_reason')).to eq('voice_agent_sip_profile_missing')
    expect(call_session.metadata['ai_voice']).to be_blank
  end

  it 'reuses a recent Sipuni webhook provider call when native Janus incoming arrives after the webhook' do
    sipuni_profile, _binotel_profile, _asterisk_profile = create_native_janus_browser_profiles
    incoming_path = "/api/v1/accounts/#{account.id}/telephony/webphone/incoming"
    binding = Telephony::NumberBinding.sync_from_voice_channel!(sipuni_profile.inbox.channel)
    provider_call_ref = 'sipuni:1782935393.293686'
    existing_call_session = create(
      :telephony_call_session,
      account: account,
      inbox: sipuni_profile.inbox,
      conversation: create(:conversation, account: account, inbox: sipuni_profile.inbox),
      number_binding: binding,
      provider: 'sipuni',
      provider_call_sid: '1782935393.293686',
      external_call_ref: provider_call_ref,
      status: 'ringing',
      direction: 'inbound',
      from_number: '+77475318623',
      to_number: binding.phone_number,
      started_at: 10.seconds.ago,
      metadata: {
        'metadata' => {
          'source' => 'sipuni_http_api',
          'operator_internal_extension' => sipuni_profile.internal_extension
        }
      }
    )

    post incoming_path,
         params: {
           inbox_id: sipuni_profile.inbox_id,
           provider: 'sipuni',
           call_ref: 'raw-sipuni-call-id@91.215.136.2:8217',
           from: 'sip:+77475318623@91.215.136.2:8217',
           session_key: "sip_profile:#{sipuni_profile.id}",
           sip_profile_id: sipuni_profile.id,
           internal_extension: sipuni_profile.internal_extension
         }.merge(sip_presence_params(sipuni_profile)),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload')
    expect(payload).to include(
      'call_sid' => provider_call_ref,
      'callSid' => provider_call_ref,
      'provider' => 'sipuni',
      'status' => 'ringing',
      'inbox_id' => sipuni_profile.inbox_id
    )
    expect(account.telephony_call_sessions.where(provider: 'sipuni').count).to eq(1)
    expect(account.telephony_call_sessions.where("external_call_ref LIKE 'sipuni:janus:%'")).to be_empty
    expect(existing_call_session.reload.metadata.dig('metadata', 'janus_call_ref')).to eq('raw-sipuni-call-id@91.215.136.2:8217')
    expect(existing_call_session.metadata.dig('metadata', 'target_sip_profile_id')).to eq(sipuni_profile.id)
  end

  it 'returns an unsupported payload for provider-managed Sipuni extensions' do
    sipuni_channel = create(
      :channel_voice,
      :sipuni,
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
      :sipuni,
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
      :sipuni,
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
      agent_aor: 'sip:9098@operator.cloud.vconsult.kz',
      availability_mode: 'browser_webphone',
      sip_password: 'older-profile-password'
    )
    latest_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: administrator,
      internal_extension: '505',
      agent_ref: 'local-profile-505',
      agent_aor: 'sip:505@operator.cloud.vconsult.kz',
      availability_mode: 'browser_webphone',
      sip_password: 'latest-profile-password'
    )

    with_modified_env(
      TELEPHONY_JANUS_WS_URL: 'wss://dev.one-link.kz/janus-sipuni'
    ) do
      post path, headers: headers, as: :json
    end

    payload = response.parsed_body.fetch('payload')
    expect(payload['provider']).to eq('sipuni')
    expect(payload['sip_profile_id']).to eq(latest_profile.id)
    expect(payload['agent_ref']).to eq('local-profile-505')
    expect(payload['sip']).to include(
      'username' => latest_profile.sip_username,
      'password' => 'latest-profile-password',
      'internal_extension' => '505'
    )
    expect(payload['browser_join_supported']).to be(true)
    expect(payload['calling_supported']).to be(true)
  end

  it 'does not fall back to a hidden account binding for a managed inbox without a SIP profile' do
    create(
      :telephony_agent_binding,
      account: account,
      user: administrator,
      provider: 'sipuni',
      agent_ref: 'legacy-agent-1001',
      agent_aor: 'sip:1001@operator.cloud.vconsult.kz'
    )
    voice_inbox.telephony_number_binding.update!(
      managed_by: Telephony::NumberBinding::MANAGED_BY_ONELINK,
      ownership_status: 'local'
    )

    post path,
         params: { inbox_id: voice_inbox.id },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['payload']).to include(
      'provider' => 'sipuni',
      'calling_supported' => false,
      'registered' => false,
      'registered_for_routing' => false,
      'reason' => 'agent_binding_missing'
    )
  end

  it 'does not record browser registration presence on a legacy agent binding without a SIP profile' do
    agent_binding = create(:telephony_agent_binding, account: account, user: administrator, provider: 'sipuni')

    post "/api/v1/accounts/#{account.id}/telephony/webphone/presence",
         params: { registered: true },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(agent_binding.reload.registered_for_routing?).to be(false)
    expect(agent_binding.metadata).not_to include('last_presence_source')
    expect(response.parsed_body['payload']).to include(
      'provider' => nil,
      'calling_supported' => false,
      'registered_for_routing' => false,
      'reason' => 'agent_binding_missing'
    )
  end

  it 'does not write browser presence to a disabled legacy binding without an inbox' do
    disabled_binding = create(
      :telephony_agent_binding,
      account: account,
      user: administrator,
      provider: 'sipuni',
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
      provider: 'sipuni',
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
      agent_aor: 'sip:504@operator.cloud.vconsult.kz',
      availability_mode: 'browser_webphone'
    )

    post "/api/v1/accounts/#{account.id}/telephony/webphone/presence",
         params: { registered: true, inbox_id: voice_inbox.id }.merge(sip_presence_params(sip_profile)),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(sip_profile.reload.registered_for_routing?).to be(true)
    expect(legacy_binding.reload.metadata).not_to include('last_presence_source')
    expect(response.parsed_body.dig('payload', 'id')).to eq(sip_profile.id)
    expect(response.parsed_body.dig('payload', 'registered_for_routing')).to be(true)
    expect(response.parsed_body.dig('payload', 'presence_update_accepted')).to be(true)
    expect(response.parsed_body.dig('payload', 'calling_supported')).to be(true)
  end

  it 'rejects an online browser presence without a complete Janus registration instance' do
    sip_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: administrator,
      internal_extension: '504',
      agent_ref: 'local-profile-504',
      agent_aor: 'sip:504@operator.cloud.vconsult.kz',
      availability_mode: 'browser_webphone'
    )
    incomplete_context = sip_presence_params(sip_profile).except(:janus_handle_id)

    post "/api/v1/accounts/#{account.id}/telephony/webphone/presence",
         params: { registered: true, inbox_id: voice_inbox.id }.merge(incomplete_context),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(sip_profile.reload.registered_for_routing?).to be(false)
    expect(response.parsed_body['payload']).to include(
      'registered_for_routing' => false,
      'presence_update_accepted' => false,
      'reason' => 'sip_profile_registration_context_incomplete'
    )
  end

  it 'rejects a second fresh browser lease for the same SIP profile' do
    sip_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: administrator,
      internal_extension: '504',
      agent_ref: 'local-profile-504',
      agent_aor: 'sip:504@operator.cloud.vconsult.kz',
      availability_mode: 'browser_webphone'
    )
    current_context = sip_presence_params(sip_profile)
    competing_context = current_context.merge(
      registration_instance_id: 'competing-registration',
      janus_session_id: 'competing-session',
      janus_handle_id: 'competing-handle'
    )

    post "/api/v1/accounts/#{account.id}/telephony/webphone/presence",
         params: { registered: true, inbox_id: voice_inbox.id }.merge(current_context),
         headers: headers,
         as: :json
    post "/api/v1/accounts/#{account.id}/telephony/webphone/presence",
         params: { registered: true, inbox_id: voice_inbox.id }.merge(competing_context),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['payload']).to include(
      'registered_for_routing' => true,
      'presence_update_accepted' => false,
      'reason' => 'sip_profile_registration_lease_conflict'
    )
    expect(sip_profile.reload.metadata.dig('registration_context', 'registration_instance_id')).to eq(
      current_context[:registration_instance_id]
    )
  end

  it 'rejects stale browser registration context after SIP profile changes' do
    sip_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: administrator,
      internal_extension: '504',
      sip_username: 'old-login',
      sip_host: 'ats01.kz.sipuni.com',
      agent_ref: 'local-profile-504',
      agent_aor: 'sip:old-login@ats01.kz.sipuni.com',
      availability_mode: 'browser_webphone'
    )
    stale_context = sip_presence_params(sip_profile)

    sip_profile.update!(
      sip_username: 'new-login',
      agent_aor: 'sip:new-login@ats01.kz.sipuni.com'
    )

    post "/api/v1/accounts/#{account.id}/telephony/webphone/presence",
         params: { registered: true, inbox_id: voice_inbox.id }.merge(stale_context),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(sip_profile.reload.registered_for_routing?).to be(false)
    expect(response.parsed_body['payload']).to include(
      'registered_for_routing' => false,
      'reason' => 'sip_profile_registration_context_mismatch'
    )
  end

  it 'ignores an offline event from a replaced Janus registration instance' do
    sip_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: administrator,
      internal_extension: '504',
      sip_username: 'current-login',
      sip_host: 'ats01.kz.sipuni.com',
      agent_ref: 'local-profile-504',
      agent_aor: 'sip:current-login@ats01.kz.sipuni.com',
      availability_mode: 'browser_webphone'
    )
    current_context = sip_presence_params(sip_profile).merge(registration_instance_id: 'current-registration')

    post "/api/v1/accounts/#{account.id}/telephony/webphone/presence",
         params: { registered: true, inbox_id: voice_inbox.id }.merge(current_context),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(sip_profile.reload.registered_for_routing?).to be(true)

    post "/api/v1/accounts/#{account.id}/telephony/webphone/presence",
         params: { registered: false, inbox_id: voice_inbox.id }.merge(
           current_context.merge(registration_instance_id: 'stale-registration')
         ),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(sip_profile.reload.registered_for_routing?).to be(true)
    expect(response.parsed_body['payload']).to include(
      'registered_for_routing' => true,
      'presence_update_accepted' => false,
      'reason' => 'sip_profile_registration_context_stale'
    )
  end

  it 'records no-inbox browser registration presence on the only browser SIP profile' do
    sip_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: administrator,
      internal_extension: '505',
      agent_ref: 'local-profile-505',
      agent_aor: 'sip:505@operator.cloud.vconsult.kz',
      availability_mode: 'browser_webphone'
    )

    post "/api/v1/accounts/#{account.id}/telephony/webphone/presence",
         params: { registered: true }.merge(sip_presence_params(sip_profile)),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(sip_profile.reload.registered_for_routing?).to be(true)
    expect(response.parsed_body.dig('payload', 'id')).to eq(sip_profile.id)
    expect(response.parsed_body.dig('payload', 'registered_for_routing')).to be(true)
    expect(response.parsed_body.dig('payload', 'calling_supported')).to be(true)
  end

  it 'does not write no-inbox browser presence to an arbitrary SIP profile when multiple profiles exist' do
    first_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: administrator,
      internal_extension: '506',
      agent_ref: 'local-profile-506',
      agent_aor: 'sip:506@operator.cloud.vconsult.kz',
      availability_mode: 'browser_webphone',
      metadata: {
        'registration_state' => 'registered',
        'presence' => 'online',
        'registered' => true,
        'last_presence_source' => 'browser_webphone',
        'last_presence_event_at' => Time.current.iso8601
      }
    )
    mark_sip_profile_registered!(first_profile)
    second_voice_inbox = create(:inbox, account: account)
    second_profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: second_voice_inbox,
      user: administrator,
      internal_extension: '507',
      agent_ref: 'local-profile-507',
      agent_aor: 'sip:507@operator.cloud.vconsult.kz',
      availability_mode: 'browser_webphone'
    )

    post "/api/v1/accounts/#{account.id}/telephony/webphone/presence",
         params: { registered: false },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(first_profile.reload.metadata).to include(
      'registration_state' => 'registered',
      'presence' => 'online',
      'registered' => true
    )
    expect(second_profile.reload.metadata).to include(
      'last_presence_source' => 'profile_config',
      'registered' => false
    )
    expect(response.parsed_body['payload']).to include(
      'calling_supported' => false,
      'registered_for_routing' => false,
      'reason' => 'ambiguous_sip_profile_presence'
    )
  end

  it 'does not write browser presence to a hidden account binding for a managed inbox without a SIP profile' do
    legacy_binding = create(
      :telephony_agent_binding,
      account: account,
      user: administrator,
      provider: 'sipuni',
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
      'provider' => 'sipuni',
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
      'provider' => nil,
      'calling_supported' => false,
      'registered' => false,
      'registered_for_routing' => false,
      'reason' => 'agent_binding_missing'
    )
  end

  it 'claims an incoming operator pool call for the current registered candidate' do
    agent_binding = create(:telephony_agent_binding, :registered, account: account, user: administrator, provider: 'sipuni')
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
    winner = create(:telephony_agent_binding, :registered, account: account, user: administrator, provider: 'sipuni')
    loser_user = create(:user, account: account, role: :agent)
    loser_headers = loser_user.create_new_auth_token
    loser = create(:telephony_agent_binding, :registered, account: account, user: loser_user, provider: 'sipuni')
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
    agent_binding = create(:telephony_agent_binding, :registered, account: account, user: administrator, provider: 'sipuni')
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
      provider: 'sipuni',
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

  it 'marks an operator call rejected when the browser phone cannot decline the SIP leg' do
    agent_binding = create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: administrator,
      provider: 'sipuni',
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

    post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
         params: { call_ref: call_session.external_call_ref, reason: 'operator_declined' },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
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
      agent_aor: 'sip:504@operator.cloud.vconsult.kz',
      metadata: {
        registration_state: 'registered',
        presence: 'online',
        last_presence_event_at: Time.current.iso8601
      }
    )
    mark_sip_profile_registered!(profile)
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

    post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
         params: { call_ref: call_session.external_call_ref, reason: 'operator_declined' },
         headers: headers,
         as: :json

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
    mark_sip_profile_registered!(profile)
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

  it 'releases a Janus-backed Sipuni browser call without calling the Sipuni hangup API' do
    create(:inbox_member, inbox: voice_inbox, user: administrator)
    provider_connection = create(:telephony_provider_connection, account: account, provider_kind: 'sipuni')
    profile = create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: administrator,
      internal_extension: '507',
      availability_mode: 'browser_webphone',
      status: 'active',
      provider_connection: provider_connection,
      agent_ref: 'sipuni-profile-507',
      agent_aor: 'sip:507@ats01.kz.sipuni.com',
      metadata: {
        registration_state: 'registered',
        presence: 'online',
        last_presence_event_at: Time.current.iso8601
      }
    )
    mark_sip_profile_registered!(profile)
    call_session = create(
      :telephony_call_session,
      account: account,
      inbox: voice_inbox,
      conversation: create(:conversation, account: account, inbox: voice_inbox),
      number_binding: Telephony::NumberBinding.find_by!(inbox_id: voice_inbox.id),
      provider: 'sipuni',
      provider_call_sid: nil,
      external_call_ref: 'sipuni:janus:48:test-ref',
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
      post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
           params: { call_ref: call_session.external_call_ref, status: 'rejected', reason: 'operator_declined' },
           headers: headers,
           as: :json

      expect(WebMock).not_to have_requested(:post, 'https://sipuni.com/api/events/call/hangup')
    end

    expect(response).to have_http_status(:ok)
    expect(call_session.reload).to have_attributes(
      status: 'rejected',
      ended_by: "user:#{administrator.id}",
      end_reason: 'operator_declined'
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
    mark_sip_profile_registered!(profile)
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

  it 'marks an operator call as no-answer when claim succeeded but browser SIP had no pending call' do
    agent_binding = create(:telephony_agent_binding, :registered, account: account, user: administrator, provider: 'sipuni')
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

    post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
         params: { call_ref: call_session.external_call_ref, status: 'no_answer', reason: 'browser_webphone_not_ready' },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('no_answer')
    expect(call_session.reload).to have_attributes(
      status: 'no_answer',
      ended_by: "user:#{administrator.id}",
      end_reason: 'browser_webphone_not_ready'
    )
  end

  it 'marks an active operator call as completed when the browser hangup releases it' do
    agent_binding = create(:telephony_agent_binding, :registered, account: account, user: administrator, provider: 'sipuni')
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

    post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
         params: { call_ref: call_session.external_call_ref, status: 'completed', reason: 'operator_hangup' },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('completed')
    expect(call_session.reload).to have_attributes(
      status: 'completed',
      ended_by: "user:#{administrator.id}",
      end_reason: 'operator_hangup'
    )
  end

  it 'treats repeated browser hangup release for a completed operator call as idempotent' do
    agent_binding = create(:telephony_agent_binding, :registered, account: account, user: administrator, provider: 'sipuni')
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

    post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
         params: { call_ref: call_session.external_call_ref, status: 'completed', reason: 'operator_hangup' },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)

    post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
         params: { call_ref: call_session.external_call_ref, status: 'completed', reason: 'remote_hangup' },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('completed')
    expect(call_session.reload).to have_attributes(
      status: 'completed',
      ended_by: "user:#{administrator.id}",
      end_reason: 'operator_hangup'
    )
  end

  it 'allows the current operator to hang up an outbound native SIP operator-mode call' do
    agent_binding = create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: administrator,
      provider: 'sipuni',
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

    post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
         params: { call_ref: call_session.external_call_ref, status: 'completed', reason: 'operator_hangup' },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('completed')
    expect(call_session.reload).to have_attributes(
      status: 'completed',
      direction: 'outbound',
      ended_by: "user:#{administrator.id}",
      end_reason: 'operator_hangup'
    )
  end

  it 'allows an inbox member to cancel a pending outbound native SIP call' do
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
        'telephony_call_ref' => 'outbound-pending-cancel-1'
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

    post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
         params: {
           call_ref: call_session.external_call_ref,
           status: 'cancelled',
           reason: 'operator_cancelled'
         },
         headers: headers,
         as: :json

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
        'telephony_call_ref' => call_session.external_call_ref
      )
    end
  end

  it 'rejects browser release attempts from unregistered operators before a claim' do
    agent_binding = create(:telephony_agent_binding, account: account, user: administrator, provider: 'sipuni')
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

  it 'ignores stale browser release attempts for AI voice calls' do
    call_session = create(
      :telephony_call_session,
      account: account,
      external_call_ref: 'ai-browser-release-ignored-1',
      status: 'in_progress',
      metadata: {
        'metadata' => {
          'route_action' => 'ai',
          'route_reason' => 'pending_conversation_ai_route'
        },
        'ai_voice' => {
          'state' => 'attached'
        }
      }
    )

    post "/api/v1/accounts/#{account.id}/telephony/webphone/reject",
         params: { call_ref: call_session.external_call_ref, reason: 'operator_rejected_from_browser' },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['payload']).to include(
      'released' => false,
      'ignored' => true,
      'reason' => 'ai_voice_call'
    )
    expect(call_session.reload).to have_attributes(status: 'in_progress', ended_by: nil, end_reason: nil)
  end

  it 'does not let a second operator release a call claimed by someone else' do
    winner = create(:telephony_agent_binding, :registered, account: account, user: administrator, provider: 'sipuni')
    loser_user = create(:user, account: account, role: :agent)
    loser_headers = loser_user.create_new_auth_token
    loser = create(:telephony_agent_binding, :registered, account: account, user: loser_user, provider: 'sipuni')
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
    winner = create(:telephony_agent_binding, :registered, account: account, user: administrator, provider: 'sipuni')
    stale_metadata_user = create(:user, account: account, role: :agent)
    stale_headers = stale_metadata_user.create_new_auth_token
    stale_binding = create(:telephony_agent_binding, :registered, account: account, user: stale_metadata_user, provider: 'sipuni')
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

  def create_native_janus_browser_profiles
    [
      { provider: 'sipuni', host: 'ats01.kz.sipuni.com', phone_number: '+15551230001', extension: '505', username: '015856100021',
        password: 'sipuni-secret' },
      { provider: 'binotel', host: 'sip53.binotel.com', phone_number: '+15551230002', extension: '901', username: 'pq4dyw5f',
        password: 'binotel-secret' },
      { provider: 'asterisk_analog', host: '10.77.0.2', phone_number: '+15551230003', extension: '9098', username: '9098',
        password: 'asterisk-secret' }
    ].map { |attributes| create_native_janus_browser_profile(attributes) }
  end

  def create_native_janus_browser_profile(attributes)
    connection = create(
      :telephony_provider_connection,
      account: account,
      provider_kind: attributes.fetch(:provider),
      host: attributes.fetch(:host),
      port: 5060,
      transport: 'udp'
    )
    channel = create_native_janus_voice_channel(attributes, connection)
    create(:inbox_member, inbox: channel.inbox, user: administrator)
    create_native_janus_sip_profile(attributes, connection, channel.inbox)
  end

  def create_native_janus_voice_channel(attributes, connection)
    create(
      :channel_voice,
      account: account,
      provider: attributes.fetch(:provider),
      phone_number: attributes.fetch(:phone_number),
      provider_config: {
        provider_kind: attributes.fetch(:provider),
        number_ref: "#{attributes.fetch(:provider)}-number-ref-#{attributes.fetch(:extension)}",
        provider_connection_id: connection.id,
        routing_mode: 'operator'
      }
    )
  end

  def create_native_janus_sip_profile(attributes, connection, inbox)
    create(
      :telephony_sip_profile,
      account: account,
      inbox: inbox,
      user: administrator,
      provider_connection: connection,
      internal_extension: attributes.fetch(:extension),
      sip_username: attributes.fetch(:username),
      sip_password: attributes.fetch(:password),
      agent_ref: "local-profile-#{attributes.fetch(:provider)}-#{attributes.fetch(:extension)}",
      agent_aor: "sip:#{attributes.fetch(:username)}@#{connection.host}",
      availability_mode: 'browser_webphone',
      status: 'active'
    )
  end
end
