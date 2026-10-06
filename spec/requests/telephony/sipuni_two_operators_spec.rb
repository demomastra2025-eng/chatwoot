require 'rails_helper'

# Two operators online on one Sipuni line. Both browsers report their own Janus
# INVITE (webphone/incoming) and the PBX reports the call per operator
# extension through the Sipuni webhook. The Sipuni report of ONE extension is
# reconciliation data: it must never replace the target and the candidate list
# the browser route of ANOTHER operator wrote, otherwise the real operator gets
# OPERATOR_NOT_CANDIDATE when he claims his own call.
RSpec.describe 'Sipuni inbound call with two operators online', type: :request do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:first_operator) { create(:user, account: account, role: :agent) }
  let(:second_operator) { create(:user, account: account, role: :agent) }
  let(:webhook_token) { 'sipuni-two-operators-token' }
  let(:caller_number) { '77070001002' }
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
        number_ref: 'sipuni-two-operators-line',
        sipuni_events_webhook_token: webhook_token,
        routing_mode: 'operator',
        operator_distribution_mode: 'broadcast'
      }
    )
  end
  let(:voice_inbox) { voice_channel.inbox }
  let(:operators) do
    {
      first: { user: first_operator, extension: '205', username: '015856100021', raw_ref: 'raw-first-invite@91.215.136.2:8201' },
      second: { user: second_operator, extension: '202', username: '015856100022', raw_ref: 'raw-second-invite@91.215.136.2:8202' }
    }
  end
  let(:auth_headers) { operators.transform_values { |operator| operator[:user].create_new_auth_token } }
  let(:profiles) do
    operators.transform_values do |operator|
      create(
        :telephony_sip_profile,
        account: account,
        inbox: voice_inbox,
        user: operator[:user],
        provider_connection: provider_connection,
        internal_extension: operator[:extension],
        sip_username: operator[:username],
        sip_password: 'sipuni-two-operators-secret',
        sip_host: 'ats01.kz.sipuni.com',
        agent_ref: "profile-two-operators-#{operator[:extension]}",
        agent_aor: "sip:#{operator[:username]}@ats01.kz.sipuni.com",
        availability_mode: 'browser_webphone',
        status: 'active'
      )
    end
  end

  before do
    account.enable_features!('channel_voice')
    operators.each_value { |operator| create(:inbox_member, inbox: voice_inbox, user: operator[:user]) }
    Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
    profiles
    allow(Telephony::Sipuni::ApiClient).to receive(:new).and_return(instance_double(Telephony::Sipuni::ApiClient, hangup: true))
    operators.each_key { |who| register_browser_profile!(who) }
  end

  # Both operators have their browser open and registered on the line.
  def register_browser_profile!(who)
    post "/api/v1/accounts/#{account.id}/telephony/webphone/presence",
         params: registration_params(who).merge(registered: true),
         headers: headers_for(who),
         as: :json
    expect(response).to have_http_status(:ok)
  end

  def headers_for(who)
    auth_headers.fetch(who)
  end

  def janus_call_ref(who)
    "sipuni:janus:#{profiles.fetch(who).id}:#{operators.fetch(who)[:raw_ref]}"
  end

  def janus_session(who)
    account.telephony_call_sessions.find_by!(external_call_ref: janus_call_ref(who))
  end

  def route_metadata(who)
    janus_session(who).metadata.fetch('metadata')
  end

  def registration_params(who)
    profile = profiles.fetch(who)
    profile.acquire_browser_registration_lease!(client_instance_id: "tab-#{who}", user_id: profile.user_id)

    {
      sip_profile_id: profile.id,
      account_id: account.id,
      inbox_id: voice_inbox.id,
      internal_extension: profile.internal_extension,
      sip_username: profile.sip_username,
      sip_host: profile.sip_host,
      agent_aor: profile.agent_aor,
      registration_config_version: profile.registration_config_version,
      registration_instance_id: profile.reload.metadata.dig('browser_registration_lease', 'registration_instance_id'),
      janus_session_id: "janus-session-#{profile.id}",
      janus_handle_id: "janus-handle-#{profile.id}",
      session_key: "sip_profile:#{profile.id}"
    }
  end

  # The operator's own INVITE, reported by his dashboard.
  def post_browser_invite(who)
    post "/api/v1/accounts/#{account.id}/telephony/webphone/incoming",
         params: {
           inbox_id: voice_inbox.id,
           provider: 'sipuni',
           call_ref: operators.fetch(who)[:raw_ref],
           from: "sip:+#{caller_number}@91.215.136.2:8201",
           internal_extension: operators.fetch(who)[:extension]
         }.merge(registration_params(who)),
         headers: headers_for(who),
         as: :json
    expect(response).to have_http_status(:ok)
  end

  # What the PBX reports for the leg it rings on one operator extension.
  def post_operator_leg_event(who, event: '1', call_id: 'sipuni-two-operators-call-1')
    operator = operators.fetch(who)
    perform_enqueued_jobs(only: Telephony::InboundRouteLifecycleJob) do
      post "/sipuni/events/#{webhook_token}",
           params: {
             event: event,
             call_id: call_id,
             src_num: caller_number,
             src_type: '1',
             dst_num: "015856#{operator[:extension]}",
             dst_type: '2',
             short_dst_num: operator[:extension],
             timestamp: Time.current.to_i,
             user_id: '015856',
             is_inner_call: '1',
             channel: "SIP/#{operator[:username]}-00000001"
           }
    end
    expect(response).to have_http_status(:ok)
  end

  def claim!(who)
    post "/api/v1/accounts/#{account.id}/telephony/webphone/claim",
         params: { call_ref: janus_call_ref(who) }, headers: headers_for(who), as: :json
  end

  # Broadcast distribution (the default): the leg of the browser that reported
  # first is the card of the call and carries the pool of every online operator;
  # the leg of the next browser is a duplicate branch of the same call.
  def expect_card_to_keep_the_browser_route
    expect(route_metadata(:first)).to include(
      'route_action' => 'operator',
      'target_user_id' => first_operator.id,
      'target_extension' => '205',
      'target_sip_profile_id' => profiles.fetch(:first).id
    )
    expect(route_metadata(:first)['sipuni_leg_kind']).not_to eq('external')
    expect_card_to_keep_the_pool
  end

  def expect_card_to_keep_the_pool
    expect(route_metadata(:first)['operator_candidate_user_ids']).to contain_exactly(first_operator.id, second_operator.id)
    expect(route_metadata(:first)['operator_candidate_sip_profile_ids']).to contain_exactly(*profiles.values.map(&:id))
  end

  def expect_duplicate_branch_to_keep_the_browser_route
    expect(route_metadata(:second)).to include(
      'route_action' => 'reject',
      'route_reason' => 'duplicate_broadcast_branch',
      'target_user_id' => second_operator.id,
      'target_extension' => '202',
      'target_sip_profile_id' => profiles.fetch(:second).id
    )
    expect(route_metadata(:second)).not_to include('operator_candidate_user_ids')
  end

  shared_examples 'a call both operators can answer' do
    it 'keeps the target and the candidates the browser route wrote' do
      expect_card_to_keep_the_browser_route
      expect_duplicate_branch_to_keep_the_browser_route
    end

    it 'lets the first operator claim the call, the second one finds it taken' do
      claim!(:first)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('payload', 'claimed')).to be(true)
      expect(janus_session(:first).metadata.dig('operator_claim', 'user_id')).to eq(first_operator.id)

      claim!(:second)
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['code']).to eq('CALL_ALREADY_CLAIMED')
    end

    it 'lets the second operator claim the call, the first one finds it taken' do
      claim!(:second)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('payload', 'claimed')).to be(true)

      claim!(:first)
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['code']).to eq('CALL_ALREADY_CLAIMED')
    end
  end

  context 'when both browsers report their INVITE, then the PBX reports both extensions' do
    before do
      post_browser_invite(:first)
      post_browser_invite(:second)
      post_operator_leg_event(:first)
      post_operator_leg_event(:second, call_id: 'sipuni-two-operators-call-2')
    end

    it_behaves_like 'a call both operators can answer'
  end

  context 'when both browsers report their INVITE, then the PBX reports the second extension first' do
    before do
      post_browser_invite(:first)
      post_browser_invite(:second)
      post_operator_leg_event(:second)
      post_operator_leg_event(:first, call_id: 'sipuni-two-operators-call-2')
    end

    it_behaves_like 'a call both operators can answer'
  end

  context 'when the PBX reports the second extension while only the first browser has reported' do
    before do
      post_browser_invite(:first)
      post_operator_leg_event(:second)
      post_browser_invite(:second)
      post_operator_leg_event(:first, call_id: 'sipuni-two-operators-call-2')
    end

    it_behaves_like 'a call both operators can answer'
  end

  context 'when the PBX reports the second extension and the second browser has not reported yet' do
    before do
      post_browser_invite(:first)
      post_operator_leg_event(:second)
    end

    it 'does not attach the report to the card of the first operator' do
      expect(janus_session(:first).provider_call_sid).to be_nil
      expect(route_metadata(:first)).not_to include('sipuni_event', 'raw_sipuni_payload')
      expect_card_to_keep_the_browser_route
    end
  end

  context 'when the PBX reports both extensions of one call under one call id' do
    before do
      post_browser_invite(:first)
      post_operator_leg_event(:second)
      post_browser_invite(:second)
      post_operator_leg_event(:first)
    end

    it_behaves_like 'a call both operators can answer'
  end

  context 'when the PBX reports both extensions before any browser' do
    before do
      post_operator_leg_event(:first)
      post_operator_leg_event(:second, call_id: 'sipuni-two-operators-call-2')
      post_browser_invite(:first)
      post_browser_invite(:second)
    end

    it_behaves_like 'a call both operators can answer'
  end

  context 'when the PBX reports that the second extension answered while only the first browser has reported' do
    before do
      post_browser_invite(:first)
      post_operator_leg_event(:second, event: '3')
      post_browser_invite(:second)
    end

    it 'keeps the target and the candidates the browser route wrote' do
      expect_card_to_keep_the_browser_route
      expect_duplicate_branch_to_keep_the_browser_route
    end
  end

  context 'when the PBX reports that the second extension answered under the call id of the first one' do
    before do
      post_browser_invite(:first)
      post_operator_leg_event(:first)
      post_browser_invite(:second)
      post_operator_leg_event(:second, event: '3')
    end

    it 'keeps the target and the candidates the browser route wrote' do
      expect_card_to_keep_the_browser_route
      expect_duplicate_branch_to_keep_the_browser_route
    end
  end

  context 'when the PBX reports the extension of the only operator who reported' do
    before do
      post_browser_invite(:first)
      post_operator_leg_event(:first)
    end

    it 'merges the report into his card' do
      expect(account.telephony_call_sessions.where(provider: 'sipuni').count).to eq(1)
      expect(janus_session(:first).provider_call_sid).to eq('sipuni-two-operators-call-1')
      expect_card_to_keep_the_browser_route
    end
  end
end
