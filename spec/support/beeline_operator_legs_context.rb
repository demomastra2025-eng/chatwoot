# Three operator browsers registered on one Beeline channel. Each browser
# receives its own INVITE for an external call and reports it as a leg of its
# own: its own call_ref (Janus handle and SIP Call-ID) through
# POST telephony/webphone/incoming.
RSpec.shared_context 'with three Beeline operator browsers' do
  let(:account) { create(:account) }
  let(:voice_phone_number) { "+1555#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}" }
  let(:caller_number) { '+70000000001' }
  let(:incoming_path) { "/api/v1/accounts/#{account.id}/telephony/webphone/incoming" }
  let(:connection) { create(:telephony_provider_connection, account: account, provider_kind: 'beeline', host: 'cloudpbx.beeline.kz') }
  let(:channel) do
    create(
      :channel_voice, account: account, provider: 'beeline', phone_number: voice_phone_number,
                      provider_config: { provider_kind: 'beeline', provider_connection_id: connection.id,
                                         number_ref: 'beeline-company-number', routing_mode: 'operator',
                                         operator_distribution_mode: 'broadcast' }
    )
  end
  let(:operators) { Array.new(3) { create(:user, account: account, role: :agent) } }
  let!(:profiles) do
    operators.each_with_index.map do |user, index|
      create(:inbox_member, inbox: channel.inbox, user: user)
      extension = (1001 + index).to_s
      create(
        :telephony_sip_profile, account: account, inbox: channel.inbox, user: user,
                                provider_connection: connection, internal_extension: extension,
                                sip_username: extension, sip_password: 'test-only-password',
                                sip_host: 'cloudpbx.beeline.kz', agent_ref: "beeline-profile-#{extension}",
                                agent_aor: "sip:#{extension}@cloudpbx.beeline.kz",
                                availability_mode: 'browser_webphone', status: 'active'
      )
    end
  end

  before do
    account.enable_features!('channel_voice')
    profiles.each { |profile| mark_sip_profile_registered!(profile) }
    allow(ActionCable.server).to receive(:broadcast)
  end

  def sip_presence_params(profile)
    profile.acquire_browser_registration_lease!(client_instance_id: 'test-tab', user_id: profile.user_id)

    {
      sip_profile_id: profile.id,
      account_id: profile.account_id,
      inbox_id: profile.inbox_id,
      internal_extension: profile.internal_extension,
      sip_username: profile.sip_username,
      sip_host: profile.sip_host,
      agent_aor: profile.agent_aor,
      registration_config_version: profile.registration_config_version,
      registration_instance_id: profile.reload.metadata.dig('browser_registration_lease', 'registration_instance_id') ||
        "registration-#{profile.id}",
      janus_session_id: "janus-session-#{profile.id}",
      janus_handle_id: "janus-handle-#{profile.id}",
      session_key: "sip_profile:#{profile.id}"
    }
  end

  def mark_sip_profile_registered!(profile)
    profile.acquire_browser_registration_lease!(client_instance_id: 'test-tab', user_id: profile.user_id)
    profile.update_browser_registration!(registered: true, registration_context: sip_presence_params(profile))
  end

  def leg_params(profile, call_id, from: caller_number)
    {
      inbox_id: channel.inbox.id, provider: 'beeline', call_ref: "beeline:janus:#{profile.id}:#{call_id}@sbc.example.test",
      from: "sip:#{from}@cloudpbx.beeline.kz", to: voice_phone_number
    }.merge(sip_presence_params(profile))
  end

  # One login per operator: a second token would replace the first session.
  let(:auth_tokens) { {} }

  def auth_headers(user)
    auth_tokens[user.id] ||= user.create_new_auth_token
  end

  def report_leg(profile, call_id, from: caller_number)
    post incoming_path, params: leg_params(profile, call_id, from: from), headers: auth_headers(profile.user), as: :json
    expect(response).to have_http_status(:ok), "leg #{call_id} was refused: #{response.body}"
  end

  def leg_session(profile, call_id)
    account.telephony_call_sessions.find_by!(external_call_ref: "beeline:janus:#{profile.id}:#{call_id}@sbc.example.test")
  end

  def logical_key(session)
    session.reload.metadata.dig('metadata', 'logical_call_key')
  end
end
