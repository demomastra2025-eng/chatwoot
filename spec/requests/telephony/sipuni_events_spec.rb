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

  before do
    account.enable_features!('channel_voice')
    create(:inbox_member, inbox: voice_inbox, user: operator)
    number_binding
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

  it 'ingests an inbound Sipuni start event through the public webhook' do
    allow(ActionCable.server).to receive(:broadcast).and_call_original

    with_modified_env(
      SIPUNI_WEBHOOK_TOKEN: token,
      SIPUNI_EXTERNAL_NUMBER: '+77070001001',
      SIPUNI_INTERNAL_NUMBER: '505'
    ) do
      perform_enqueued_jobs(only: Telephony::InboundRouteLifecycleJob) do
        post "/sipuni/events/#{token}",
             params: {
               event: '1',
               call_id: 'sipuni-call-1',
               src_num: '77070001002',
               src_type: '1',
               dst_num: '77070001001',
               dst_type: '2',
               short_dst_num: '505',
               timestamp: Time.current.to_i
             }
      end
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('success' => true, 'status' => 'accepted')

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'sipuni:sipuni-call-1')
    expect(call_session).to have_attributes(
      provider: 'sipuni',
      provider_call_sid: 'sipuni-call-1',
      status: 'ringing',
      direction: 'inbound',
      from_number: '+77070001002',
      to_number: '+77070001001',
      inbox_id: voice_inbox.id,
      number_binding_id: number_binding.id
    )
    expect(call_session.metadata.dig('metadata', 'operator_candidate_sip_profile_ids')).to be_present
    expect(call_session.metadata.dig('metadata', 'operator_internal_extension')).to eq('505')
    expect(call_session.metadata.dig('metadata', 'operator_candidates')).to include(
      hash_including(
        'sip_profile_id' => kind_of(Integer),
        'user_id' => operator.id,
        'user_name' => operator.name,
        'internal_extension' => '505'
      )
    )
    event = account.telephony_events.where(call_session: call_session).find { |record| record.event_key.start_with?('sipuni:') }
    expect(event.event_key).to eq('sipuni:sipuni-call-1:1:ringing')
    expect(ActionCable.server).to have_received(:broadcast).with(
      operator.pubsub_token,
      hash_including(
        event: 'voice_call.incoming',
        data: hash_including(
          provider: 'sipuni',
          callSid: 'sipuni:sipuni-call-1',
          inbox_id: voice_inbox.id,
          from_number: '+77070001002',
          to_number: '+77070001001',
          operator_internal_extension: '505',
          operator_candidates: include(
            hash_including(
              user_id: operator.id,
              name: operator.name,
              internal_extension: '505'
            )
          )
        )
      )
    )
  end

  it 'waits for the Sipuni internal operator leg before broadcasting an answerable incoming call' do
    broadcasts = []
    allow(ActionCable.server).to receive(:broadcast) do |pubsub_token, event|
      broadcasts << [pubsub_token, event]
    end

    with_modified_env(
      SIPUNI_WEBHOOK_TOKEN: token,
      SIPUNI_EXTERNAL_NUMBER: '+77070001001',
      SIPUNI_INTERNAL_NUMBER: '505'
    ) do
      perform_enqueued_jobs(only: Telephony::InboundRouteLifecycleJob) do
        post "/sipuni/events/#{token}",
             params: {
               event: '1',
               call_id: 'sipuni-greeting-then-operator',
               src_num: '77070001002',
               src_type: '1',
               short_src_num: '77070001002',
               dst_num: '77070001001_id244276',
               dst_type: '1',
               short_dst_num: '77070001001_id244276',
               timestamp: 1_782_846_643,
               user_id: '015856',
               channel: 'SIP/013997 77003470027-00041b4b'
             }
      end

      expect(response).to have_http_status(:ok)
      expect(broadcasts.filter { |_token, event| event[:event] == 'voice_call.incoming' }).to be_empty

      call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'sipuni:sipuni-greeting-then-operator')
      expect(call_session.metadata.dig('metadata', 'sipuni_operator_leg')).to be(false)
      expect(call_session.metadata.dig('metadata', 'sipuni_leg_kind')).to eq('external')

      perform_enqueued_jobs(only: Telephony::InboundRouteLifecycleJob) do
        post "/sipuni/events/#{token}",
             params: {
               event: '1',
               call_id: 'sipuni-greeting-then-operator',
               src_num: '77070001002',
               src_type: '1',
               short_src_num: '77070001002',
               dst_num: '015856505',
               dst_type: '2',
               short_dst_num: '505',
               timestamp: 1_782_846_659,
               user_id: '015856',
               is_inner_call: '1',
               channel: 'SIP/015856100021-00041b4c',
               pbxdstnum: '100021'
             }
      end
    end

    incoming_broadcasts = broadcasts.filter { |_token, event| event[:event] == 'voice_call.incoming' }
    expect(incoming_broadcasts.size).to eq(1)
    pubsub_token, event = incoming_broadcasts.first
    expect(pubsub_token).to eq(operator.pubsub_token)
    expect(event).to include(event: 'voice_call.incoming')
    expect(event[:data]).to include(
      provider: 'sipuni',
      callSid: 'sipuni:sipuni-greeting-then-operator',
      operator_internal_extension: '505'
    )
    expect(event.dig(:data, :operator_candidates)).to include(
      hash_including(
        user_id: operator.id,
        internal_extension: '505'
      )
    )

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'sipuni:sipuni-greeting-then-operator')
    expect(call_session.metadata.dig('metadata', 'sipuni_operator_leg')).to be(true)
    expect(call_session.metadata.dig('metadata', 'sipuni_leg_kind')).to eq('operator')
    expect(call_session.metadata.dig('metadata', 'operator_candidate_sip_profile_ids')).to be_present
  end

  it 'deduplicates repeated Sipuni lifecycle events with different timestamps' do
    allow(ActionCable.server).to receive(:broadcast).and_call_original

    with_modified_env(
      SIPUNI_WEBHOOK_TOKEN: token,
      SIPUNI_EXTERNAL_NUMBER: '+77070001001',
      SIPUNI_INTERNAL_NUMBER: '505'
    ) do
      perform_enqueued_jobs(only: Telephony::InboundRouteLifecycleJob) do
        2.times do |index|
          post "/sipuni/events/#{token}",
               params: {
                 event: '1',
                 call_id: 'sipuni-repeat-call-1',
                 src_num: '77070001002',
                 src_type: '1',
                 dst_num: '77070001001',
                 dst_type: '2',
                 short_dst_num: '505',
                 timestamp: Time.current.to_i + index
               }

          expect(response).to have_http_status(:ok)
        end
      end
    end

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'sipuni:sipuni-repeat-call-1')
    expect(account.telephony_events.where(call_session: call_session, event_key: 'sipuni:sipuni-repeat-call-1:1:ringing').count).to eq(1)
    expect(call_session.legs.count { |leg| leg['event_key'] == 'sipuni:sipuni-repeat-call-1:1:ringing' }).to eq(1)
    expect(ActionCable.server).to have_received(:broadcast).with(
      operator.pubsub_token,
      hash_including(
        event: 'voice_call.incoming',
        data: hash_including(callSid: 'sipuni:sipuni-repeat-call-1')
      )
    ).once
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

    perform_enqueued_jobs(only: Telephony::InboundRouteLifecycleJob) do
      post "/sipuni/events/#{token}",
           params: {
             event: '1',
             call_id: 'sipuni-channel-token-call',
             src_num: '77070001002',
             src_type: '1',
             dst_num: '77070001001',
             dst_type: '2',
             short_dst_num: '505',
             timestamp: Time.current.to_i
           }
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('success' => true, 'status' => 'accepted')

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'sipuni:sipuni-channel-token-call')
    expect(call_session).to have_attributes(
      provider: 'sipuni',
      inbox_id: voice_inbox.id,
      number_binding_id: number_binding.id
    )
  end

  it 'processes terminal Sipuni events inline so the call UI closes without queue latency' do
    started_at = Time.current.to_i - 30

    with_modified_env(
      SIPUNI_WEBHOOK_TOKEN: token,
      SIPUNI_EXTERNAL_NUMBER: '+77070001001',
      SIPUNI_INTERNAL_NUMBER: '505'
    ) do
      perform_enqueued_jobs(only: Telephony::InboundRouteLifecycleJob) do
        post "/sipuni/events/#{token}",
             params: {
               event: '1',
               call_id: 'sipuni-terminal-inline-1',
               src_num: '77070001002',
               src_type: '1',
               dst_num: '77070001001',
               dst_type: '2',
               short_dst_num: '505',
               timestamp: started_at
             }
      end

      clear_enqueued_jobs

      expect do
        post "/sipuni/events/#{token}",
             params: {
               event: '2',
               status: 'NOANSWER',
               call_id: 'sipuni-terminal-inline-1',
               src_num: '77070001002',
               src_type: '1',
               dst_num: '77070001001',
               dst_type: '2',
               short_dst_num: '505',
               timestamp: started_at + 30
             }
      end.not_to have_enqueued_job(Telephony::InboundRouteLifecycleJob)
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('success' => true, 'status' => 'processed')

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'sipuni:sipuni-terminal-inline-1')
    expect(call_session).to have_attributes(
      status: 'no_answer',
      ended_by: nil,
      end_reason: 'NOANSWER'
    )
    expect(call_session.ended_at.to_i).to eq(started_at + 30)
    expect(account.telephony_events.where(call_session: call_session, event_key: 'sipuni:sipuni-terminal-inline-1:2:NOANSWER').count).to eq(1)
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
end
