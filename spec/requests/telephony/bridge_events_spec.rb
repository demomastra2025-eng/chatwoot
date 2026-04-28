require 'rails_helper'
require 'tempfile'

RSpec.describe 'Telephony Bridge Events', type: :request do
  let(:account) { create(:account) }
  let(:voice_phone_number) { "+1555#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}" }
  let(:voice_channel) { create(:channel_voice, :fonoster, account: account, phone_number: voice_phone_number) }
  let(:voice_inbox) { voice_channel.inbox }
  let(:path) { '/telephony/internal/events' }
  let(:compatibility_path) { '/internal/voice/inbound/event' }

  before do
    account.enable_features!('channel_voice')
    Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
  end

  it 'creates inbound conversation state from bridge callback payloads' do
    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             event_key: 'evt-1',
             call_ref: 'call-in-1',
             event: 'session_started',
             status: 'ringing',
             direction: 'FROM_PSTN',
             number_ref: voice_inbox.telephony_number_binding.number_ref,
             ingress_number: voice_channel.phone_number,
             caller_number: '+15557654321',
             metadata: {
               source: 'bridge-spec'
             }
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['call_ref']).to eq('call-in-1')

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'call-in-1')
    expect(call_session.status).to eq('ringing')
    expect(call_session.direction).to eq('inbound')
    expect(call_session.inbox_id).to eq(voice_inbox.id)
    expect(call_session.number_binding.number_ref).to eq(voice_inbox.telephony_number_binding.number_ref)
    expect(call_session.conversation).to be_present
    expect(call_session.conversation.contact.phone_number).to eq('+15557654321')
    expect(account.telephony_events.find_by!(event_key: 'evt-1')).to be_processed
  end

  it 'accepts camelCase bridge payloads from the voice runtime' do
    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             eventKey: 'evt-2',
             callRef: 'call-in-2',
             eventType: 'session_started',
             status: 'ringing',
             direction: 'FROM_PSTN',
             numberRef: voice_inbox.telephony_number_binding.number_ref,
             ingressNumber: voice_channel.phone_number,
             callerNumber: '+15557650000',
             providerCallSid: 'provider-call-2',
             transcriptRef: 'transcript-2',
             metadata: {
               source: 'bridge-camel'
             }
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['call_ref']).to eq('call-in-2')

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'call-in-2')
    expect(call_session.status).to eq('ringing')
    expect(call_session.provider_call_sid).to eq('provider-call-2')
    expect(call_session.transcript_ref).to eq('transcript-2')
    expect(call_session.number_binding.number_ref).to eq(voice_inbox.telephony_number_binding.number_ref)
    expect(call_session.conversation).to be_present
    expect(call_session.conversation.contact.phone_number).to eq('+15557650000')
    expect(account.telephony_events.find_by!(event_key: 'evt-2')).to be_processed
  end

  it 'supports the native bridge compatibility event path' do
    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post compatibility_path,
           params: {
             event_key: 'evt-compat',
             call_ref: 'call-in-compat',
             event: 'session_started',
             status: 'ringing',
             direction: 'FROM_PSTN',
             number_ref: voice_inbox.telephony_number_binding.number_ref,
             ingress_number: voice_channel.phone_number,
             caller_number: '+15557650001'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['call_ref']).to eq('call-in-compat')
    expect(account.telephony_call_sessions.find_by!(external_call_ref: 'call-in-compat')).to be_present
  end

  it 'acks and stores raw events even when CRM conversation side effects fail' do
    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post compatibility_path,
           params: {
             event_key: 'evt-side-effect-failure-1',
             call_ref: 'call-side-effect-failure-1',
             event: 'session_started',
             status: 'ringing',
             direction: 'FROM_PSTN',
             ingress_number: '+199****9999',
             caller_number: '+155****0002'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret',
             'X-Account-Id' => account.id.to_s
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'status' => 'ok',
      'call_ref' => 'call-side-effect-failure-1'
    )

    event = account.telephony_events.find_by!(event_key: 'evt-side-effect-failure-1')
    expect(event).to be_failed
    expect(event.error_message).to include('Unable to resolve voice inbox')

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'call-side-effect-failure-1')
    expect(call_session).to have_attributes(status: 'ringing', direction: 'inbound')
    expect(call_session.conversation).to be_nil
  end

  it 'uses the idempotency header as the event key when the payload omits one' do
    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post compatibility_path,
           params: {
             call_ref: 'call-in-header-idempotency',
             event: 'session_started',
             status: 'ringing',
             direction: 'FROM_PSTN',
             number_ref: voice_inbox.telephony_number_binding.number_ref,
             ingress_number: voice_channel.phone_number,
             caller_number: '+15557650002'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret',
             'X-Idempotency-Key' => 'evt-header-1'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(account.telephony_events.find_by!(event_key: 'evt-header-1')).to be_processed
  end

  it 'resolves outbound event ownership and chatwoot associations from account header and metadata' do
    user = create(:user, account: account, role: :agent)
    agent_binding = create(:telephony_agent_binding, account: account, user: user)
    contact = create(:contact, account: account, phone_number: '+15557650003')
    contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: contact.phone_number)
    conversation = create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post compatibility_path,
           params: {
             event_key: 'evt-outbound-meta',
             call_ref: 'call-outbound-meta',
             event: 'answered',
             status: 'answered',
             direction: 'OUTBOUND_API',
             from_number: voice_channel.phone_number,
             to_number: contact.phone_number,
             metadata: {
               chatwoot_conversation_id: conversation.id,
               chatwoot_contact_id: contact.id,
               chatwoot_inbox_id: voice_inbox.id,
               chatwoot_user_id: user.id
             }
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret',
             'X-Account-Id' => account.id.to_s
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'call-outbound-meta')
    expect(call_session.status).to eq('in_progress')
    expect(call_session.direction).to eq('outbound')
    expect(call_session.conversation_id).to eq(conversation.id)
    expect(call_session.contact_id).to eq(contact.id)
    expect(call_session.inbox_id).to eq(voice_inbox.id)
    expect(call_session.number_binding_id).to eq(voice_inbox.telephony_number_binding.id)
    expect(call_session.agent_binding_id).to eq(agent_binding.id)
  end

  it 'uses the account header when the payload includes blank account fields' do
    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post compatibility_path,
           params: {
             event_key: 'evt-blank-account-1',
             call_ref: 'call-outbound-blank-account',
             event: 'answered',
             status: 'answered',
             direction: 'OUTBOUND_API',
             account_id: '',
             accountId: '',
             from_number: voice_channel.phone_number,
             to_number: '+15557650004'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret',
             'X-Account-Id' => account.id.to_s
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'call-outbound-blank-account')
    expect(call_session.status).to eq('in_progress')
    expect(call_session.direction).to eq('outbound')
    expect(account.telephony_events.find_by!(event_key: 'evt-blank-account-1')).to be_processed
  end

  it 'handles repeated late bridge events for the same call without raising uniqueness errors' do
    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post compatibility_path,
           params: {
             event_key: 'evt-dup-start-1',
             call_ref: 'call-in-dup-1',
             event: 'session_started',
             status: 'ringing',
             direction: 'FROM_PSTN',
             number_ref: voice_inbox.telephony_number_binding.number_ref,
             ingress_number: voice_channel.phone_number,
             caller_number: '+15557650005'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret',
             'X-Account-Id' => account.id.to_s
           },
           as: :json

      expect(response).to have_http_status(:ok)

      late_event_payload = {
        call_ref: 'call-in-dup-1',
        direction: 'FROM_PSTN',
        account_id: account.id.to_s
      }

      post compatibility_path,
           params: late_event_payload.merge(
             event_key: 'evt-dup-answered-1',
             event: 'answered',
             status: 'answered'
           ),
           headers: {
             'X-Bridge-Secret' => 'bridge-secret',
             'X-Account-Id' => account.id.to_s
           },
           as: :json

      expect(response).to have_http_status(:ok)

      post compatibility_path,
           params: late_event_payload.merge(
             event_key: 'evt-dup-answered-1',
             event: 'answered',
             status: 'answered'
           ),
           headers: {
             'X-Bridge-Secret' => 'bridge-secret',
             'X-Account-Id' => account.id.to_s
           },
           as: :json

      expect(response).to have_http_status(:ok)

      post compatibility_path,
           params: late_event_payload.merge(
             event_key: 'evt-dup-completed-1',
             event: 'session_completed',
             status: 'completed'
           ),
           headers: {
             'X-Bridge-Secret' => 'bridge-secret',
             'X-Account-Id' => account.id.to_s
           },
           as: :json

      expect(response).to have_http_status(:ok)

      post compatibility_path,
           params: late_event_payload.merge(
             event_key: 'evt-dup-completed-1',
             event: 'session_completed',
             status: 'completed'
           ),
           headers: {
             'X-Bridge-Secret' => 'bridge-secret',
             'X-Account-Id' => account.id.to_s
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(account.telephony_call_sessions.where(external_call_ref: 'call-in-dup-1').count).to eq(1)
    expect(account.telephony_events.where(event_key: 'evt-dup-answered-1').count).to eq(1)
    expect(account.telephony_events.where(event_key: 'evt-dup-completed-1').count).to eq(1)
    expect(account.telephony_events.find_by!(event_key: 'evt-dup-answered-1')).to be_processed
    expect(account.telephony_events.find_by!(event_key: 'evt-dup-completed-1')).to be_processed
    expect(account.telephony_call_sessions.find_by!(external_call_ref: 'call-in-dup-1').status).to eq('completed')
  end

  it 'writes inbound event request and response to the dedicated telephony debug log' do
    debug_log_file = Tempfile.new('telephony-event-debug')

    with_modified_env(
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret',
      TELEPHONY_DEBUG_LOGGING: 'true',
      TELEPHONY_BRIDGE_DEBUG_LOG_PATH: debug_log_file.path
    ) do
      post compatibility_path,
           params: {
             event_key: 'evt-log-1',
             call_ref: 'call-in-log-1',
             event: 'session_started',
             status: 'ringing',
             direction: 'FROM_PSTN',
             number_ref: voice_inbox.telephony_number_binding.number_ref,
             ingress_number: voice_channel.phone_number,
             caller_number: '+15557650009'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret',
             'X-Account-Id' => account.id.to_s
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)

    written_events = File.readlines(debug_log_file.path).map { |line| JSON.parse(line) }
    expect(written_events).to include(
      include(
        'event' => 'telephony_inbound_event_request',
        'path' => compatibility_path,
        'call_ref' => 'call-in-log-1',
        'account_id' => account.id.to_s,
        'event_type' => 'session_started'
      ),
      include(
        'event' => 'telephony_inbound_event_response',
        'path' => compatibility_path,
        'call_ref' => 'call-in-log-1',
        'response_payload' => include('status' => 'ok', 'call_ref' => 'call-in-log-1')
      )
    )
  ensure
    debug_log_file&.close!
  end
end
