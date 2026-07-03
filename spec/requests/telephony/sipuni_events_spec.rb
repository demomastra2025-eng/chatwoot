require 'rails_helper'

RSpec.describe 'Sipuni events webhook', type: :request do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:operator) { create(:user, account: account, role: :administrator) }
  let(:provider_connection) do
    create(
      :telephony_provider_connection,
      account: account,
      provider_kind: 'sipuni',
      host: 'ats01.kz.sipuni.com',
      port: 5060,
      transport: 'udp',
      username: '990001000021'
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
        number_ref: 'sipuni-main-line',
        routing_mode: 'operator',
        operator_distribution_mode: 'broadcast'
      }
    )
  end
  let(:voice_inbox) { voice_channel.inbox }
  let(:number_binding) { Telephony::NumberBinding.sync_from_voice_channel!(voice_channel) }
  let(:token) { 'sipuni-webhook-token' }
  let(:sip_profile) do
    create(
      :telephony_sip_profile,
      account: account,
      inbox: voice_inbox,
      user: operator,
      provider_connection: provider_connection,
      internal_extension: '505',
      sip_username: '990001000021',
      sip_password: 'test-sip-password',
      sip_host: 'ats01.kz.sipuni.com',
      agent_ref: 'sipuni-profile-505',
      fonoster_agent_ref: nil,
      agent_aor: 'sip:990001000021@ats01.kz.sipuni.com',
      availability_mode: 'browser_webphone',
      status: 'active',
      last_synced_at: Time.current,
      metadata: {
        registration_state: 'registered',
        registered: true,
        last_presence_event_at: Time.current.iso8601
      }
    )
  end

  before do
    account.enable_features!('channel_voice')
    create(:inbox_member, inbox: voice_inbox, user: operator)
    number_binding
    sip_profile
  end

  it 'stores an unmatched inbound Sipuni start event as reconciliation-only data' do
    allow(ActionCable.server).to receive(:broadcast).and_call_original

    post_unmatched_sipuni_start(call_id: 'sipuni-call-1')

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('success' => true, 'status' => 'reconciliation_pending')
    expect(account.telephony_call_sessions.where(provider: 'sipuni')).to be_empty

    event = account.telephony_events.find_by!(event_key: 'sipuni:sipuni-call-1:1:ringing')
    expect(event).to have_attributes(
      event_type: 'session_started',
      status: 'processed',
      call_session_id: nil
    )
    expect(event.payload.dig('metadata', 'sipuni_webhook_mode')).to eq('reconciliation_only')
    expect(event.payload.dig('metadata', 'sipuni_webhook_unmatched')).to be(true)
    expect(ActionCable.server).not_to have_received(:broadcast).with(
      operator.pubsub_token,
      hash_including(event: 'voice_call.incoming')
    )
  end

  it 'does not broadcast unmatched Sipuni operator-leg webhooks for browser webphone inboxes' do
    broadcasts = []
    allow(ActionCable.server).to receive(:broadcast) do |pubsub_token, event|
      broadcasts << [pubsub_token, event]
    end

    post_unmatched_sipuni_start(call_id: 'sipuni-greeting-then-operator')

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('success' => true, 'status' => 'reconciliation_pending')
    expect(account.telephony_call_sessions.where(provider: 'sipuni')).to be_empty
    expect(account.telephony_events.where(event_key: 'sipuni:sipuni-greeting-then-operator:1:ringing').count).to eq(1)
    expect(broadcasts.filter { |_token, event| event[:event] == 'voice_call.incoming' }).to be_empty
  end

  it 'deduplicates repeated unmatched Sipuni webhook events without creating a live call' do
    allow(ActionCable.server).to receive(:broadcast).and_call_original

    2.times do |index|
      post_unmatched_sipuni_start(call_id: 'sipuni-repeat-call-1', timestamp: Time.current.to_i + index)
      expect(response).to have_http_status(:ok)
    end

    expect(account.telephony_call_sessions.where(provider: 'sipuni')).to be_empty
    expect(account.telephony_events.where(event_key: 'sipuni:sipuni-repeat-call-1:1:ringing').count).to eq(1)
    expect(ActionCable.server).not_to have_received(:broadcast).with(
      operator.pubsub_token,
      hash_including(event: 'voice_call.incoming')
    )
  end

  it 'attaches Sipuni webhook lifecycle to an active native Janus call instead of creating a duplicate provider call' do
    allow(ActionCable.server).to receive(:broadcast)

    started_at = Time.zone.at(1_782_846_659)
    janus_call_ref, janus_call_session = create_native_janus_sipuni_call_session(started_at)

    post_native_sipuni_webhook_event(started_at)

    expect(response).to have_http_status(:ok)
    expect(account.telephony_call_sessions.where(provider: 'sipuni').count).to eq(1)
    expect(account.telephony_call_sessions.find_by(external_call_ref: 'sipuni:sipuni-native-race-1')).to be_nil
    expect(janus_call_session.reload).to have_attributes(
      provider_call_sid: 'sipuni-native-race-1',
      status: 'ringing'
    )
    expect(janus_call_session.metadata.dig('metadata', 'sipuni_native_webphone_call_ref')).to eq(janus_call_ref)
    expect(janus_call_session.metadata.dig('metadata', 'sipuni_native_webphone_correlation')).to be(true)
    expect(ActionCable.server).not_to have_received(:broadcast).with(
      operator.pubsub_token,
      hash_including(event: 'voice_call.incoming')
    )
  end

  it 'ingests an outbound Sipuni start event through the public webhook' do
    with_modified_env(
      SIPUNI_WEBHOOK_TOKEN: token,
      SIPUNI_EXTERNAL_NUMBER: '+77070001001',
      SIPUNI_INTERNAL_NUMBER: '505'
    ) do
      perform_enqueued_jobs(only: Telephony::InboundRouteLifecycleJob) do
        post "/sipuni/events/#{token}",
             params: {
               event: '1',
               call_id: 'sipuni-outbound-1',
               src_num: '015856505',
               src_type: '2',
               short_src_num: '505',
               dst_num: '77017553379',
               dst_type: '1',
               short_dst_num: '77017553379',
               timestamp: Time.current.to_i
             }
      end
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('success' => true, 'status' => 'accepted')

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'sipuni:sipuni-outbound-1')
    expect(call_session).to have_attributes(
      provider: 'sipuni',
      provider_call_sid: 'sipuni-outbound-1',
      status: 'ringing',
      direction: 'outbound',
      from_number: '+77070001001',
      to_number: '+77017553379',
      inbox_id: voice_inbox.id,
      number_binding_id: number_binding.id
    )
  end

  it 'authenticates a Sipuni webhook token stored on the voice channel' do
    voice_channel.update!(
      provider_config: voice_channel.provider_config.merge(
        'sipuni_events_webhook_token' => token
      )
    )

    post_unmatched_sipuni_start(call_id: 'sipuni-channel-token-call', set_legacy_token: false)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('success' => true, 'status' => 'reconciliation_pending')
    expect(account.telephony_call_sessions.where(provider: 'sipuni')).to be_empty
    event = account.telephony_events.find_by!(event_key: 'sipuni:sipuni-channel-token-call:1:ringing')
    expect(event.payload.dig('metadata', 'sipuni_webhook_mode')).to eq('reconciliation_only')
  end

  it 'queues terminal Sipuni events and reconciles them against an existing native Janus call' do
    started_at = Time.zone.at(Time.current.to_i - 30)
    _janus_call_ref, janus_call_session = create_native_janus_sipuni_call_session(started_at)

    with_modified_env(
      SIPUNI_WEBHOOK_TOKEN: token,
      SIPUNI_EXTERNAL_NUMBER: voice_channel.phone_number,
      SIPUNI_INTERNAL_NUMBER: sip_profile.internal_extension
    ) do
      clear_enqueued_jobs

      expect do
        post "/sipuni/events/#{token}",
             params: native_sipuni_terminal_webhook_event_params(started_at)
      end.to have_enqueued_job(Telephony::InboundRouteLifecycleJob).on_queue('telephony_realtime')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('success' => true, 'status' => 'accepted')

      perform_enqueued_jobs(only: Telephony::InboundRouteLifecycleJob)
    end

    call_session = janus_call_session.reload
    expect(account.telephony_call_sessions.where(provider: 'sipuni').count).to eq(1)
    expect(call_session).to have_attributes(
      provider_call_sid: 'sipuni-native-race-1',
      status: 'no_answer',
      ended_by: nil,
      end_reason: 'NOANSWER'
    )
    expect(call_session.ended_at.to_i).to eq(started_at.to_i + 30)
    expect(account.telephony_events.where(call_session: call_session, event_key: 'sipuni:sipuni-native-race-1:2:NOANSWER').count).to eq(1)
  end

  it 'resolves an outbound event by SIP profile username when extensions repeat across Sipuni numbers' do
    second_operator = create(:user, account: account, role: :agent)
    second_voice_channel = create(
      :channel_voice,
      account: account,
      provider: 'sipuni',
      phone_number: '+77070000000',
      provider_config: {
        provider_kind: 'sipuni',
        provider_connection_id: provider_connection.id,
        number_ref: 'sipuni-second-line',
        routing_mode: 'operator',
        operator_distribution_mode: 'broadcast'
      }
    )
    second_voice_inbox = second_voice_channel.inbox
    create(:inbox_member, inbox: second_voice_inbox, user: second_operator)
    second_number_binding = Telephony::NumberBinding.sync_from_voice_channel!(second_voice_channel)
    create(
      :telephony_sip_profile,
      account: account,
      inbox: second_voice_inbox,
      user: second_operator,
      provider_connection: provider_connection,
      internal_extension: '505',
      sip_username: '015856100099',
      sip_password: 'test-second-sip-password',
      sip_host: 'ats01.kz.sipuni.com',
      agent_ref: 'sipuni-profile-second-505',
      fonoster_agent_ref: nil,
      agent_aor: 'sip:015856100099@ats01.kz.sipuni.com',
      availability_mode: 'browser_webphone',
      status: 'active',
      last_synced_at: Time.current,
      metadata: {
        registration_state: 'registered',
        registered: true,
        last_presence_event_at: Time.current.iso8601
      }
    )

    with_modified_env(
      SIPUNI_WEBHOOK_TOKEN: token,
      SIPUNI_EXTERNAL_NUMBER: nil,
      SIPUNI_INTERNAL_NUMBER: nil
    ) do
      perform_enqueued_jobs(only: Telephony::InboundRouteLifecycleJob) do
        post "/sipuni/events/#{token}",
             params: {
               event: '1',
               call_id: 'sipuni-shared-extension-outbound',
               user_id: '015856',
               src_num: '015856505',
               src_type: '2',
               short_src_num: '505',
               dst_num: '77017553379',
               dst_type: '1',
               short_dst_num: '77017553379',
               channel: 'SIP/015856100099-00000001',
               timestamp: Time.current.to_i
             }
      end
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('success' => true, 'status' => 'accepted')

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'sipuni:sipuni-shared-extension-outbound')
    expect(call_session).to have_attributes(
      provider: 'sipuni',
      provider_call_sid: 'sipuni-shared-extension-outbound',
      status: 'ringing',
      direction: 'outbound',
      from_number: '+77070000000',
      to_number: '+77017553379',
      inbox_id: second_voice_inbox.id,
      number_binding_id: second_number_binding.id
    )
    expect(call_session.metadata.dig('metadata', 'operator_candidate_user_ids')).to eq([second_operator.id])
  end

  it 'rejects requests with a wrong token' do
    with_modified_env(SIPUNI_WEBHOOK_TOKEN: token) do
      post '/sipuni/events/wrong-token',
           params: { event: '1', call_id: 'sipuni-call-unauthorized' }
    end

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to include('success' => false, 'error' => 'unauthorized')
  end

  def post_unmatched_sipuni_start(call_id:, timestamp: Time.current.to_i, set_legacy_token: true)
    env = if set_legacy_token
            {
              SIPUNI_WEBHOOK_TOKEN: token,
              SIPUNI_EXTERNAL_NUMBER: voice_channel.phone_number,
              SIPUNI_INTERNAL_NUMBER: sip_profile.internal_extension
            }
          else
            {}
          end

    with_modified_env(env) do
      perform_enqueued_jobs(only: Telephony::InboundRouteLifecycleJob) do
        post "/sipuni/events/#{token}",
             params: unmatched_sipuni_start_params(call_id: call_id, timestamp: timestamp)
      end
    end
  end

  def unmatched_sipuni_start_params(call_id:, timestamp: Time.current.to_i)
    {
      event: '1',
      call_id: call_id,
      src_num: '77070001002',
      src_type: '1',
      dst_num: "015856#{sip_profile.internal_extension}",
      dst_type: '2',
      short_dst_num: sip_profile.internal_extension,
      timestamp: timestamp,
      user_id: '015856',
      is_inner_call: '1',
      channel: "SIP/#{sip_profile.sip_username}-00000001"
    }
  end

  def create_native_janus_sipuni_call_session(started_at)
    janus_call_ref = "sipuni:janus:#{sip_profile.id}:raw-sipuni-call-id@91.215.136.2:8217"
    call_session = create(
      :telephony_call_session,
      account: account,
      inbox: voice_inbox,
      conversation: create(:conversation, account: account, inbox: voice_inbox),
      number_binding: number_binding,
      provider: 'sipuni',
      external_call_ref: janus_call_ref,
      provider_call_sid: nil,
      status: 'ringing',
      direction: 'inbound',
      from_number: '+77070001002',
      to_number: '+77070001001',
      started_at: started_at,
      metadata: native_janus_sipuni_call_metadata(janus_call_ref)
    )

    [janus_call_ref, call_session]
  end

  def native_janus_sipuni_call_metadata(janus_call_ref)
    {
      'metadata' => {
        'source' => 'browser_janus_sip',
        'target_sip_profile_id' => sip_profile.id,
        'operator_internal_extension' => '505'
      },
      'fast_incoming_broadcast' => {
        'event_key' => "route_lookup:#{janus_call_ref}:session_started"
      }
    }
  end

  def post_native_sipuni_webhook_event(started_at)
    with_modified_env(
      SIPUNI_WEBHOOK_TOKEN: token,
      SIPUNI_EXTERNAL_NUMBER: '+77070001001',
      SIPUNI_INTERNAL_NUMBER: '505'
    ) do
      perform_enqueued_jobs(only: Telephony::InboundRouteLifecycleJob) do
        post "/sipuni/events/#{token}", params: native_sipuni_webhook_event_params(started_at)
      end
    end
  end

  def native_sipuni_terminal_webhook_event_params(started_at)
    native_sipuni_webhook_event_params(started_at).merge(
      event: '2',
      status: 'NOANSWER',
      timestamp: started_at.to_i + 30
    )
  end

  def native_sipuni_webhook_event_params(started_at)
    {
      event: '1',
      call_id: 'sipuni-native-race-1',
      src_num: '77070001002',
      src_type: '1',
      dst_num: '015856505',
      dst_type: '2',
      short_dst_num: '505',
      timestamp: started_at.to_i,
      user_id: '015856',
      is_inner_call: '1',
      channel: 'SIP/990001000021-00000001'
    }
  end
end
