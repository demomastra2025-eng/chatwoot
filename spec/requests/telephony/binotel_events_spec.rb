require 'rails_helper'

RSpec.describe 'Binotel events webhook', type: :request do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:operator) { create(:user, account: account, role: :administrator) }
  let(:token) { 'binotel-webhook-token' }
  let(:provider_connection) do
    create(
      :telephony_provider_connection,
      account: account,
      provider_kind: 'binotel',
      host: 'sip53.binotel.com',
      port: 5060,
      transport: 'udp',
      username: 'binotel-company-1'
    )
  end
  let(:voice_channel) do
    create(
      :channel_voice,
      account: account,
      provider: 'binotel',
      phone_number: '+77010002001',
      provider_config: {
        provider_kind: 'binotel',
        provider_connection_id: provider_connection.id,
        number_ref: 'binotel-main-line',
        binotel_events_webhook_token: token,
        routing_mode: 'operator',
        operator_distribution_mode: 'broadcast'
      }
    )
  end
  let(:voice_inbox) { voice_channel.inbox }
  let(:number_binding) { Telephony::NumberBinding.sync_from_voice_channel!(voice_channel) }

  before do
    account.enable_features!('channel_voice')
    create(:inbox_member, inbox: voice_inbox, user: operator)
    number_binding
  end

  it 'creates one missed inbound call from repeated API CALL COMPLETED webhooks' do
    2.times { post_binotel_event(binotel_call_details) }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('status' => 'success')

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'binotel:9001001')
    expect(call_session).to have_attributes(
      provider: 'binotel',
      provider_call_sid: '9001001',
      status: 'missed',
      direction: 'inbound',
      from_number: '+77070002002',
      to_number: '+77010002001',
      answered_at: nil,
      end_reason: 'NOANSWER',
      inbox_id: voice_inbox.id,
      number_binding_id: number_binding.id
    )
    expect(call_session.ended_at).to eq(call_session.started_at + 30.seconds)
    expect(account.telephony_call_sessions.where(provider_call_sid: '9001001').count).to eq(1)
    expect(account.telephony_events.where(event_key: 'binotel:9001001:completed:NOANSWER').count).to eq(1)
  end

  it 'uses the final disposition instead of an unanswered operator branch' do
    details = binotel_call_details.merge(
      generalCallID: '9001002',
      startTime: Time.current.to_i - 75,
      disposition: 'ANSWER',
      billsec: 45,
      historyData: [
        { internalNumber: '201', disposition: 'NOANSWER', billsec: 0 },
        { internalNumber: '202', disposition: 'ANSWER', billsec: 45 }
      ]
    )

    post_binotel_event(details)

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'binotel:9001002')
    expect(call_session).to have_attributes(status: 'completed', duration_seconds: 45)
    expect(call_session.answered_at).to be_present
    expect(call_session.metadata.dig('metadata', 'binotel_history_data')).to contain_exactly(
      hash_including('internalNumber' => '201', 'disposition' => 'NOANSWER'),
      hash_including('internalNumber' => '202', 'disposition' => 'ANSWER')
    )
  end

  it 'attaches the Binotel result to a matching native Janus call' do
    started_at = Time.zone.at(Time.current.to_i - 30)
    janus_call = create(
      :telephony_call_session,
      account: account,
      inbox: voice_inbox,
      conversation: create(:conversation, account: account, inbox: voice_inbox),
      number_binding: number_binding,
      provider: 'binotel',
      external_call_ref: 'binotel:janus:profile-1:provider-call-id',
      provider_call_sid: nil,
      status: 'ringing',
      direction: 'inbound',
      from_number: '+77070002002',
      to_number: '+77010002001',
      started_at: started_at,
      metadata: { 'metadata' => { 'source' => 'browser_janus_sip' } }
    )

    post_binotel_event(
      binotel_call_details.merge(startTime: (started_at - 90.seconds).to_i, waitsec: 120)
    )

    event = account.telephony_events.find_by!(event_key: 'binotel:9001001:completed:NOANSWER')
    expect(event.error_message).to be_nil
    expect(event).to have_attributes(status: 'processed', call_session_id: janus_call.id)
    expect(account.telephony_call_sessions.where(provider: 'binotel').count).to eq(1)
    expect(janus_call.reload).to have_attributes(provider_call_sid: '9001001', status: 'missed')
    expect(janus_call.metadata.dig('metadata', 'binotel_native_webphone_correlation')).to be(true)
  end

  it 'attaches an outbound Binotel result to the native Janus call without a duplicate' do
    started_at = Time.zone.at(Time.current.to_i - 75)
    janus_call = create(
      :telephony_call_session,
      account: account,
      inbox: voice_inbox,
      conversation: create(:conversation, account: account, inbox: voice_inbox),
      number_binding: number_binding,
      provider: 'binotel',
      external_call_ref: 'binotel:local:outbound-call-id',
      provider_call_sid: nil,
      status: 'answered',
      direction: 'outbound',
      from_number: voice_channel.phone_number,
      to_number: '+77070002002',
      started_at: started_at,
      answered_at: started_at + 30.seconds,
      metadata: { 'metadata' => { 'source' => 'browser_janus_sip' } }
    )
    details = binotel_call_details.merge(
      generalCallID: '9001003',
      startTime: started_at.to_i,
      callType: 1,
      disposition: 'ANSWER',
      billsec: 45
    )

    post_binotel_event(details)

    expect(account.telephony_call_sessions.where(provider: 'binotel').count).to eq(1)
    expect(janus_call.reload).to have_attributes(provider_call_sid: '9001003', status: 'completed')
    expect(janus_call.metadata.dig('metadata', 'binotel_native_webphone_correlation')).to be(true)
  end

  it 'rejects an unknown token without creating telephony data' do
    post '/binotel/events/wrong-token', params: { requestType: 'apiCallCompleted', callDetails: binotel_call_details }

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq('status' => 'error')
    expect(account.telephony_call_sessions.where(provider: 'binotel')).to be_empty
    expect(account.telephony_events.where("event_key LIKE 'binotel:%'")).to be_empty
  end

  it 'rejects a legacy token after a canonical token is configured' do
    voice_channel.update!(
      provider_config: voice_channel.provider_config_hash.merge('binotel_webhook_token' => 'legacy-token')
    )

    post '/binotel/events/legacy-token', params: { requestType: 'apiCallCompleted', callDetails: binotel_call_details }

    expect(response).to have_http_status(:unauthorized)
    expect(account.telephony_call_sessions.where(provider: 'binotel')).to be_empty
  end

  it 'accepts a legacy token only when the canonical token is absent' do
    provider_config = voice_channel.provider_config_hash.except('binotel_events_webhook_token')
    voice_channel.update!(provider_config: provider_config.merge('binotel_webhook_token' => 'legacy-token'))

    post '/binotel/events/legacy-token', params: { requestType: 'apiCallSettings' }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('status' => 'success')
  end

  it 'acknowledges a non-completed Binotel request without creating telephony data' do
    post "/binotel/events/#{token}", params: {
      requestType: 'apiCallSettings',
      callDetails: { binotel_call_details[:generalCallID] => binotel_call_details }
    }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('status' => 'success')
    expect(account.telephony_call_sessions.where(provider: 'binotel')).to be_empty
    expect(account.telephony_events.where("event_key LIKE 'binotel:%'")).to be_empty
  end

  it 'ignores completed callbacks with missing or unknown call types' do
    [binotel_call_details.except(:callType), binotel_call_details.merge(callType: 2)].each do |details|
      post_binotel_event(details)
      expect(response).to have_http_status(:ok)
    end

    expect(account.telephony_call_sessions.where(provider: 'binotel')).to be_empty
    expect(account.telephony_events.where("event_key LIKE 'binotel:%'")).to be_empty
  end

  it 'retries a transient failed side effect without duplicating the call or message' do
    payload = Telephony::Binotel::EventAdapter.new(
      requestType: 'apiCallCompleted',
      callDetails: binotel_call_details,
      chatwoot_account_id: account.id,
      chatwoot_inbox_id: voice_inbox.id,
      number_ref: 'binotel-main-line',
      ingress_number: voice_channel.phone_number,
      received_at: Time.current.iso8601
    ).payload
    sync_attempts = 0
    allow(Telephony::EventsIngestionService).to receive(:new).and_wrap_original do |constructor, **arguments|
      service = constructor.call(**arguments)
      allow(service).to receive(:sync_voice_message!).and_wrap_original do |method, *args, **kwargs|
        sync_attempts += 1
        raise 'transient message failure' if sync_attempts == 1

        method.call(*args, **kwargs)
      end
      service
    end

    expect do
      Telephony::InboundRouteLifecycleJob.perform_now(payload, retry_failed: true)
    end.to raise_error(Telephony::InboundRouteLifecycleJob::ProcessingFailedError)
    expect(account.telephony_events.find_by!(event_key: 'binotel:9001001:completed:NOANSWER')).to be_failed

    expect do
      Telephony::InboundRouteLifecycleJob.perform_now(payload, retry_failed: true)
    end.not_to raise_error

    event = account.telephony_events.find_by!(event_key: 'binotel:9001001:completed:NOANSWER')
    expect(event).to be_processed
    expect(account.telephony_call_sessions.where(provider_call_sid: '9001001').count).to eq(1)
    expect(event.call_session.exact_voice_message).to be_present
  end

  def post_binotel_event(details)
    perform_enqueued_jobs(only: Telephony::InboundRouteLifecycleJob) do
      post "/binotel/events/#{token}",
           params: { requestType: 'apiCallCompleted', callDetails: { details[:generalCallID].to_s => details } }
    end
  end

  def binotel_call_details
    {
      companyID: 'company-1',
      generalCallID: '9001001',
      startTime: Time.current.to_i - 30,
      callType: 0,
      internalNumber: '801',
      externalNumber: '77070002002',
      waitsec: 30,
      billsec: 0,
      disposition: 'NOANSWER',
      pbxNumberData: { number: '+77010002001', name: 'Main line' },
      historyData: [{ internalNumber: '201', disposition: 'NOANSWER', billsec: 0 }]
    }
  end
end
