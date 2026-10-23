require 'rails_helper'

# One operator signs in on two clinic computers in turn: the line must follow
# her at once when she asks for it, and a tab that goes away must give the line
# up without waiting for the lease to expire.
RSpec.describe 'Telephony webphone line takeover', type: :request do
  let(:account) { create(:account) }
  let(:operator) { create(:user, account: account, role: :agent) }
  let(:headers) { operator.create_new_auth_token }
  let(:token_path) { "/api/v1/accounts/#{account.id}/telephony/webphone/token" }
  let(:release_path) { "/api/v1/accounts/#{account.id}/telephony/webphone/release" }
  let(:connection) do
    create(:telephony_provider_connection, account: account, provider_kind: 'binotel', host: 'sip53.binotel.com', port: 5060, transport: 'udp')
  end
  let(:channel) do
    create(
      :channel_voice,
      account: account,
      provider: 'binotel',
      phone_number: '+15551239001',
      provider_config: {
        provider_kind: 'binotel', number_ref: 'binotel-number-ref-7810', provider_connection_id: connection.id, routing_mode: 'operator'
      }
    )
  end
  let!(:profile) do
    create(:inbox_member, inbox: channel.inbox, user: operator)
    create(
      :telephony_sip_profile,
      account: account, inbox: channel.inbox, user: operator, provider_connection: connection,
      internal_extension: '7810', sip_username: 'line7810', sip_password: 'binotel-secret',
      agent_ref: 'local-profile-binotel-7810', agent_aor: 'sip:line7810@sip53.binotel.com',
      availability_mode: 'browser_webphone', status: 'active'
    )
  end

  around do |example|
    with_modified_env(TELEPHONY_BINOTEL_JANUS_WS_URL: 'wss://dev.one-link.kz/janus-binotel') { example.run }
  end

  before { account.enable_features!('channel_voice') }

  def request_token(client_instance_id:, browser_instance_id:, takeover: nil)
    params = { inbox_id: profile.inbox_id, client_instance_id: client_instance_id, browser_instance_id: browser_instance_id }
    params[:lease_mode] = 'takeover' if takeover
    post token_path, params: params, headers: headers, as: :json
    response.parsed_body.fetch('payload')
  end

  def register!(payload)
    profile.update_browser_registration!(
      registered: true,
      registration_context: {
        registration_config_version: profile.reload.registration_config_version,
        registration_instance_id: payload.fetch('registration_instance_id'),
        janus_session_id: 'janus-session-pc-1',
        janus_handle_id: 'janus-handle-pc-1'
      }
    )
  end

  describe 'moving the line here' do
    it 'keeps the line on the other computer for an automatic retry' do
      register!(request_token(client_instance_id: 'tab-pc-1', browser_instance_id: 'browser-pc-1'))

      retry_payload = request_token(client_instance_id: 'tab-pc-2', browser_instance_id: 'browser-pc-2')

      expect(retry_payload).to include('calling_supported' => false, 'reason' => 'sip_profile_registration_lease_owned_by_another_tab')
      expect(retry_payload.keys).not_to include('registration_release_key', 'sip_password')
      expect(profile.reload).to be_registered_for_routing
    end

    it 'takes the line over on the explicit request and tells the old tab' do
      old_payload = request_token(client_instance_id: 'tab-pc-1', browser_instance_id: 'browser-pc-1')
      register!(old_payload)
      allow(ActionCable.server).to receive(:broadcast)

      new_payload = request_token(client_instance_id: 'tab-pc-2', browser_instance_id: 'browser-pc-2', takeover: true)

      expect(new_payload).to include('calling_supported' => true, 'registration_release_key' => be_present)
      expect(new_payload['registration_instance_id']).not_to eq(old_payload['registration_instance_id'])
      expect(profile.reload.metadata.dig('browser_registration_lease', 'browser_instance_id')).to eq('browser-pc-2')
      expect(ActionCable.server).to have_received(:broadcast).with(
        operator.pubsub_token,
        {
          event: 'telephony.webphone_lease_taken_over',
          data: {
            account_id: account.id, sip_profile_id: profile.id, inbox_id: profile.inbox_id,
            registration_instance_id: old_payload['registration_instance_id']
          }
        }
      )
    end

    it 'says why the line stays on the other computer during a call' do
      register!(request_token(client_instance_id: 'tab-pc-1', browser_instance_id: 'browser-pc-1'))
      create(
        :telephony_call_session,
        account: account,
        status: 'in_progress',
        metadata: { 'operator_claim' => { 'user_id' => operator.id, 'sip_profile_id' => profile.id } }
      )

      payload = request_token(client_instance_id: 'tab-pc-2', browser_instance_id: 'browser-pc-2', takeover: true)

      expect(payload).to include('calling_supported' => false, 'takeover_refused' => 'call_in_progress')
      expect(profile.reload).to be_registered_for_routing
    end

    it 'never takes the line for a follower tab that only observes' do
      register!(request_token(client_instance_id: 'tab-pc-1', browser_instance_id: 'browser-pc-1'))

      post token_path,
           params: { inbox_id: profile.inbox_id, client_instance_id: 'tab-follower', lease_mode: 'observe' },
           headers: headers,
           as: :json

      expect(response.parsed_body.dig('payload', 'calling_supported')).to be(false)
      expect(profile.reload.metadata.dig('browser_registration_lease', 'client_instance_id')).to eq('tab-pc-1')
    end
  end

  describe 'releasing the line from a closing tab' do
    it 'frees the line with the release key alone, so another computer gets it on its next retry' do
      old_payload = request_token(client_instance_id: 'tab-pc-1', browser_instance_id: 'browser-pc-1')
      register!(old_payload)

      # A beacon carries no auth headers (and a sign-in elsewhere has revoked the session anyway).
      post release_path, params: { release_key: old_payload.fetch('registration_release_key') }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('payload', 'released')).to be(true)
      expect(profile.reload).not_to be_registered_for_routing
      expect(profile.metadata).not_to have_key('browser_registration_lease')
      expect(request_token(client_instance_id: 'tab-pc-2', browser_instance_id: 'browser-pc-2')).to include('calling_supported' => true)
    end

    it 'works after a sign-in on the other computer replaced the session' do
      old_payload = request_token(client_instance_id: 'tab-pc-1', browser_instance_id: 'browser-pc-1')
      register!(old_payload)
      operator.activate_auth_client!('client-of-pc-2')

      post release_path, params: { release_key: old_payload.fetch('registration_release_key') }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(profile.reload.metadata).not_to have_key('browser_registration_lease')
    end

    it 'does not release a newer lease with the key of an older tab' do
      old_payload = request_token(client_instance_id: 'tab-pc-1', browser_instance_id: 'browser-pc-1')
      new_payload = request_token(client_instance_id: 'tab-pc-2', browser_instance_id: 'browser-pc-2', takeover: true)

      post release_path, params: { release_key: old_payload.fetch('registration_release_key') }

      expect(response.parsed_body.dig('payload', 'released')).to be(false)
      expect(profile.reload.metadata.dig('browser_registration_lease', 'registration_instance_id'))
        .to eq(new_payload.fetch('registration_instance_id'))
    end

    it 'refuses a forged key and a key of another account' do
      other_account = create(:account)
      other_account.enable_features!('channel_voice')
      payload = request_token(client_instance_id: 'tab-pc-1', browser_instance_id: 'browser-pc-1')

      post release_path, params: { release_key: 'forged' }
      expect(response).to have_http_status(:forbidden)

      post "/api/v1/accounts/#{other_account.id}/telephony/webphone/release", params: { release_key: payload.fetch('registration_release_key') }
      expect(response).to have_http_status(:forbidden)
      expect(profile.reload.metadata).to have_key('browser_registration_lease')
    end
  end
end
