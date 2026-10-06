require 'rails_helper'

# A Sipuni call can ring an external number (a mobile phone) next to the
# browser operator. The PBX reports that external leg through the Sipuni
# webhook (leg kind external). The operator's own leg reaches OneLink through
# POST webphone/incoming (the Janus INVITE of the browser): it is an operator
# leg by construction, so the external report must neither hide it nor make
# it unclaimable.
RSpec.describe 'Sipuni inbound call with an external PBX leg', type: :request do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:operator) { create(:user, account: account, role: :agent) }
  let(:headers) { operator.create_new_auth_token }
  let(:webhook_token) { 'sipuni-external-leg-token' }
  let(:caller_number) { '77070001002' }
  let(:sipuni_call_id) { 'sipuni-external-leg-call-1' }
  let(:raw_janus_call_ref) { 'raw-external-leg-invite@91.215.136.2:8201' }
  let(:provider_connection) do
    create(
      :telephony_provider_connection,
      account: account,
      provider_kind: 'sipuni',
      host: 'ats01.kz.sipuni.com',
      port: 5060,
      transport: 'udp',
      username: '015856'
    )
  end
  let(:voice_channel) do
    create(
      :channel_voice,
      account: account,
      provider: 'sipuni',
      phone_number: '+77070001001',
      provider_config: {
        provider_kind: 'sipuni',
        provider_connection_id: provider_connection.id,
        number_ref: 'sipuni-external-leg-line',
        sipuni_events_webhook_token: webhook_token,
        routing_mode: 'operator',
        operator_distribution_mode: 'broadcast'
      }
    )
  end
  let(:voice_inbox) { voice_channel.inbox }
  let(:sip_profile) do
    create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: operator,
      provider_connection: provider_connection,
      internal_extension: '205',
      sip_username: '015856100021',
      sip_password: 'sipuni-external-leg-secret',
      sip_host: 'ats01.kz.sipuni.com',
      agent_ref: 'profile-external-leg-205',
      agent_aor: 'sip:015856100021@ats01.kz.sipuni.com',
      availability_mode: 'browser_webphone',
      status: 'active'
    )
  end
  let(:janus_call_ref) { "sipuni:janus:#{sip_profile.id}:#{raw_janus_call_ref}" }
  let(:claim_path) { "/api/v1/accounts/#{account.id}/telephony/webphone/claim" }
  let(:reject_path) { "/api/v1/accounts/#{account.id}/telephony/webphone/reject" }

  before do
    account.enable_features!('channel_voice')
    create(:inbox_member, inbox: voice_inbox, user: operator)
    Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
    sip_profile
    allow(Telephony::Sipuni::ApiClient).to receive(:new).and_return(instance_double(Telephony::Sipuni::ApiClient, hangup: true))
  end

  def registration_params
    sip_profile.acquire_browser_registration_lease!(client_instance_id: 'test-tab', user_id: sip_profile.user_id)

    {
      sip_profile_id: sip_profile.id,
      account_id: account.id,
      inbox_id: voice_inbox.id,
      internal_extension: sip_profile.internal_extension,
      sip_username: sip_profile.sip_username,
      sip_host: sip_profile.sip_host,
      agent_aor: sip_profile.agent_aor,
      registration_config_version: sip_profile.registration_config_version,
      registration_instance_id: sip_profile.reload.metadata.dig('browser_registration_lease', 'registration_instance_id'),
      janus_session_id: "janus-session-#{sip_profile.id}",
      janus_handle_id: "janus-handle-#{sip_profile.id}",
      session_key: "sip_profile:#{sip_profile.id}"
    }
  end

  # The browser operator's INVITE, reported by the dashboard.
  def post_browser_invite
    post "/api/v1/accounts/#{account.id}/telephony/webphone/incoming",
         params: {
           inbox_id: voice_inbox.id,
           provider: 'sipuni',
           call_ref: raw_janus_call_ref,
           from: "sip:+#{caller_number}@91.215.136.2:8201",
           internal_extension: sip_profile.internal_extension
         }.merge(registration_params),
         headers: headers,
         as: :json
    expect(response).to have_http_status(:ok)
  end

  # What the PBX reports for the leg it rings on an external (mobile) number:
  # the destination is an outside number, not an internal extension.
  def external_leg_params(overrides = {})
    {
      event: '1',
      call_id: sipuni_call_id,
      src_num: caller_number,
      src_type: '1',
      dst_num: '77075550000',
      dst_type: '1',
      timestamp: Time.current.to_i,
      user_id: '015856'
    }.merge(overrides)
  end

  def post_external_leg_event(overrides = {})
    perform_enqueued_jobs(only: Telephony::InboundRouteLifecycleJob) do
      post "/sipuni/events/#{webhook_token}", params: external_leg_params(overrides)
    end
    expect(response).to have_http_status(:ok)
  end

  def janus_session
    account.telephony_call_sessions.find_by!(external_call_ref: janus_call_ref)
  end

  def claim!
    post claim_path, params: { call_ref: janus_call_ref }, headers: headers, as: :json
  end

  def reject!
    post reject_path, params: { call_ref: janus_call_ref, reason: 'operator_declined' }, headers: headers, as: :json
  end

  context 'when the PBX reports the external leg after the browser INVITE' do
    before do
      post_browser_invite
      post_external_leg_event
    end

    it 'merges the external leg report into the browser operator session' do
      expect(account.telephony_call_sessions.where(provider: 'sipuni').count).to eq(1)
      expect(janus_session).to have_attributes(provider_call_sid: sipuni_call_id)
      expect(janus_session.metadata.dig('metadata', 'operator_candidate_user_ids')).to eq([operator.id])
    end

    it 'does not turn the browser operator leg into an external leg' do
      route_metadata = janus_session.metadata.fetch('metadata')

      expect(route_metadata['sipuni_operator_leg']).not_to be(false)
      expect(route_metadata['sipuni_leg_kind']).not_to eq('external')
    end

    it 'lets the addressed operator claim the call' do
      claim!

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('payload', 'claimed')).to be(true)
      expect(janus_session.metadata.dig('operator_claim', 'user_id')).to eq(operator.id)
    end

    it 'lets the addressed operator reject the call' do
      reject!

      expect(response).to have_http_status(:ok)
      expect(janus_session).to have_attributes(status: 'rejected', ended_by: "user:#{operator.id}")
    end
  end

  context 'when the PBX reports the external leg before the browser INVITE' do
    before do
      post_external_leg_event
      post_browser_invite
    end

    it 'stores the early report without creating a duplicate call' do
      expect(account.telephony_call_sessions.where(provider: 'sipuni').count).to eq(1)
      expect(account.telephony_events.where(event_key: "sipuni:#{sipuni_call_id}:1:ringing").count).to eq(1)
    end

    it 'lets the addressed operator claim the call' do
      claim!

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('payload', 'claimed')).to be(true)
    end

    it 'lets the addressed operator reject the call' do
      reject!

      expect(response).to have_http_status(:ok)
      expect(janus_session).to have_attributes(status: 'rejected', ended_by: "user:#{operator.id}")
    end
  end

  context 'when a card exists only because of an external leg report' do
    it 'keeps the external leg unclaimable by the browser' do
      post_external_leg_event
      call_session = account.telephony_call_sessions.create!(
        provider: 'sipuni',
        external_call_ref: "sipuni:#{sipuni_call_id}",
        provider_call_sid: sipuni_call_id,
        inbox: voice_inbox,
        number_binding: voice_inbox.telephony_number_binding,
        direction: 'inbound',
        status: 'ringing',
        from_number: "+#{caller_number}",
        to_number: voice_channel.phone_number,
        metadata: {
          'metadata' => {
            'route_action' => 'operator',
            'sipuni_operator_leg' => false,
            'sipuni_leg_kind' => 'external',
            'operator_candidate_user_ids' => [operator.id],
            'operator_candidate_sip_profile_ids' => [sip_profile.id]
          }
        }
      )
      register_browser_profile!

      post claim_path, params: { call_ref: call_session.external_call_ref }, headers: headers, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig('details', 'reason')).to eq('sipuni_operator_leg_not_ready')
    end
  end

  def register_browser_profile!
    post "/api/v1/accounts/#{account.id}/telephony/webphone/presence",
         params: registration_params.merge(registered: true),
         headers: headers,
         as: :json
  end
end
