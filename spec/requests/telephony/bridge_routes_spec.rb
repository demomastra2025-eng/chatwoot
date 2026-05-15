require 'rails_helper'
require 'tempfile'

RSpec.describe 'Telephony Bridge Routes', type: :request do
  let(:account) { create(:account) }
  let(:voice_channel) { create(:channel_voice, :fonoster, account: account, phone_number: voice_phone_number) }
  let(:voice_phone_number) { "+1555#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}" }
  let(:voice_inbox) { voice_channel.inbox }
  let(:number_binding) { voice_inbox.telephony_number_binding }
  let(:path) { '/internal/voice/inbound/route' }

  before do
    account.enable_features!('channel_voice')
    Telephony::NumberBinding.sync_from_voice_channel!(voice_channel)
  end

  it 'returns an operator route when the configured operator is available' do
    agent_binding = create(
      :telephony_agent_binding,
      :registered,
      account: account,
      agent_aor: 'sip:1001@example.test',
      enabled: true
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      fallback_mode: 'app'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-1',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15559999999'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'operator',
      'agent_aor' => 'sip:1001@example.test',
      'reason' => 'operator_route',
      'number_ref' => number_binding.number_ref,
      'inbox_id' => voice_inbox.id,
      'account_id' => account.id
    )
    expect(response.parsed_body['recording']).to include(
      'enabled' => true,
      'source' => 'onelink_runtime',
      'storage_provider' => 'onelink_storage'
    )
    expect(response.parsed_body).not_to have_key('fallback_mode')
    expect(response.parsed_body).not_to have_key('fallback_app_ref')
  end

  it 'does not persist route lifecycle or voice-call bubble for diagnostic audit probes' do
    caller_number = '+15550001010'
    contact = create(:contact, account: account, phone_number: caller_number)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: caller_number)
    create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :open
    )

    agent_binding = create(
      :telephony_agent_binding,
      :registered,
      account: account,
      agent_aor: 'sip:1001@example.test',
      enabled: true
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      expect do
        post path,
             params: {
               call_ref: 'audit-call',
               ingress_number: voice_channel.phone_number,
               caller_number: caller_number,
               diagnostic: true
             },
             headers: { 'X-Bridge-Secret' => 'bridge-secret' },
             as: :json
      end.not_to change(Telephony::CallSession, :count)
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'operator',
      'reason' => 'operator_route'
    )
    expect(Message.voice_calls.where(source_id: 'voice_call:audit-call')).not_to exist
  end

  it 'rejects operator-mode calls when the browser registration is stale' do
    agent_binding = create(
      :telephony_agent_binding,
      account: account,
      agent_aor: 'sip:1001@example.test',
      enabled: true,
      last_synced_at: 3.minutes.ago,
      metadata: {
        registration_state: 'registered',
        registered: true,
        last_presence_event_at: 3.minutes.ago.iso8601
      }
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-stale-browser-registration',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155****0103'
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('agent_aor')
  end

  it 'rejects operator-mode calls while browser registration is still flapping' do
    agent_binding = create(
      :telephony_agent_binding,
      account: account,
      agent_aor: 'sip:1001@example.test',
      enabled: true,
      last_synced_at: 20.seconds.ago,
      metadata: {
        registration_state: 'registered',
        registered: true,
        last_presence_event_at: 20.seconds.ago.iso8601,
        last_unregistered_event_at: 2.seconds.ago.iso8601
      }
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-flapping-browser-registration',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155****0104'
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('agent_aor')
  end

  it 'routes operator-mode calls after browser re-registers following a disconnect' do
    agent_binding = create(
      :telephony_agent_binding,
      account: account,
      agent_aor: 'sip:1001@example.test',
      enabled: true,
      last_synced_at: Time.current,
      metadata: {
        registration_state: 'registered',
        registered: true,
        last_presence_event_at: Time.current.iso8601,
        last_unregistered_event_at: 2.seconds.ago.iso8601
      }
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-after-browser-reregister',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155****0105'
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'operator',
      'agent_aor' => agent_binding.agent_aor
    )
  end

  it 'returns a registered operator pool for inbox members and excludes offline or busy bindings' do
    primary_user = create(:user, account: account, role: :agent)
    secondary_user = create(:user, account: account, role: :agent)
    busy_user = create(:user, account: account, role: :agent)
    offline_user = create(:user, account: account, role: :agent)
    non_member_user = create(:user, account: account, role: :agent)
    [primary_user, secondary_user, busy_user, offline_user].each { |user| create(:inbox_member, inbox: voice_inbox, user: user) }

    primary_binding = create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: primary_user,
      agent_ref: 'fonoster-agent-primary',
      agent_aor: 'sip:1001@example.test'
    )
    create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: secondary_user,
      agent_ref: 'fonoster-agent-secondary',
      agent_aor: 'sip:1002@example.test'
    )
    busy_binding = create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: busy_user,
      agent_ref: 'fonoster-agent-busy',
      agent_aor: 'sip:1003@example.test'
    )
    create(
      :telephony_agent_binding,
      account: account,
      user: offline_user,
      agent_ref: 'fonoster-agent-offline',
      agent_aor: 'sip:1004@example.test'
    )
    create(
      :telephony_agent_binding,
      :registered,
      account: account,
      user: non_member_user,
      agent_ref: 'fonoster-agent-non-member',
      agent_aor: 'sip:1005@example.test'
    )
    create(:telephony_call_session, account: account, agent_binding: busy_binding, status: 'in_progress')

    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: primary_binding.agent_ref,
      operator_agent_aor: primary_binding.agent_aor,
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-operator-pool',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155****0100'
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'operator',
      'agent_aor' => 'sip:1001@example.test',
      'agent_aors' => contain_exactly('sip:1001@example.test', 'sip:1002@example.test'),
      'operator_pool' => true,
      'operator_pool_size' => 2
    )
    expect(response.parsed_body['operator_candidates']).to contain_exactly(
      include('agent_ref' => 'fonoster-agent-primary', 'agent_aor' => 'sip:1001@example.test', 'user_id' => primary_user.id),
      include('agent_ref' => 'fonoster-agent-secondary', 'agent_aor' => 'sip:1002@example.test', 'user_id' => secondary_user.id)
    )

    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'inbound-route-operator-pool')
    expect(call_session.metadata.dig('metadata', 'operator_candidate_user_ids')).to contain_exactly(primary_user.id, secondary_user.id)
    expect(call_session.metadata.dig('metadata', 'operator_candidate_agent_refs')).to contain_exactly(
      'fonoster-agent-primary',
      'fonoster-agent-secondary'
    )
  end

  it 'rejects operator-mode calls when a SIP operator AOR has no registration binding' do
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_aor: 'sip:unregistered@example.test',
      fallback_mode: 'app'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-no-operator-registration',
             ingress_number: voice_channel.phone_number,
             caller_number: '+155****0101'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('agent_aor')
    expect(response.parsed_body).not_to have_key('app_ref')
  end

  it 'does not fall back from operator mode to AI when the operator target is missing' do
    number_binding.routing_policy.assign_attributes(
      mode: 'operator',
      operator_agent_ref: nil,
      operator_agent_aor: nil,
      ai_enabled: true,
      ai_deployment_mode: 'onelink_managed',
      onelink_ai_app_ref: 'captain-ai-app-ref',
      fallback_mode: 'app'
    )
    number_binding.routing_policy.save!(validate: false)

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-no-operator-registration-ai-side',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15555550102'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('app_ref')
  end

  it 'creates an idempotent native call lifecycle during route lookup' do
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_aor: 'sip:1001@example.test',
      fallback_mode: 'reject'
    )

    route_request = lambda do
      post path,
           params: {
             call_ref: 'inbound-route-lifecycle',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15551239998'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      expect do
        2.times { route_request.call }
      end.to change(Telephony::CallSession, :count).by(1)
                                                   .and change(Conversation, :count).by(1)
                                                                                    .and change(Message, :count).by(1)
    end

    expect(response).to have_http_status(:ok)
    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'inbound-route-lifecycle')
    expect(call_session).to have_attributes(
      status: 'ringing',
      direction: 'inbound',
      inbox_id: voice_inbox.id,
      number_binding_id: number_binding.id,
      from_number: '+15551239998',
      to_number: voice_channel.phone_number
    )
    expect(call_session.conversation).to be_present
    expect(call_session.conversation.identifier).to eq('inbound-route-lifecycle')
    expect(call_session.conversation.messages.where(content_type: 'voice_call').count).to eq(1)
  end

  it 'rejects non-SIP operator targets instead of returning a non-executable operator route' do
    number_binding.routing_policy.update_columns(
      mode: 'operator',
      operator_agent_aor: 'operator1',
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-destination',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15551230001'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('agent_aor')
    expect(response.parsed_body).not_to have_key('destination')
  end

  it 'persists a voice-call timeline item for a rejected route on an existing conversation' do
    caller_number = '+15550000000'
    contact = create(:contact, account: account, phone_number: caller_number)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: caller_number)
    conversation = create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :open
    )

    number_binding.routing_policy.update!(mode: 'operator', fallback_mode: 'reject')

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      expect do
        post path,
             params: {
               call_ref: 'existing-conversation-rejected-route',
               ingress_number: voice_channel.phone_number,
               caller_number: caller_number
             },
             headers: {
               'X-Bridge-Secret' => 'bridge-secret'
             },
             as: :json
      end.to change(Message, :count).by(1)

      post '/internal/voice/inbound/event',
           params: {
             call_ref: 'existing-conversation-rejected-route',
             event: 'rejected',
             account_id: account.id,
             inbox_id: voice_inbox.id,
             number_ref: number_binding.number_ref,
             caller_number: caller_number,
             status: 'rejected',
             terminal: true
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    call_session = account.telephony_call_sessions.find_by!(external_call_ref: 'existing-conversation-rejected-route')
    expect(call_session.reload).to have_attributes(
      conversation_id: conversation.id,
      status: 'rejected'
    )
    voice_message = conversation.messages.voice_calls.find_by!(source_id: 'voice_call:existing-conversation-rejected-route')
    expect(voice_message.content_attributes.dig('data', 'status')).to eq('rejected')
    expect(voice_message.content_attributes.dig('data', 'call_sid')).to eq('existing-conversation-rejected-route')
  end

  it 'accepts bearer token authentication for inbound route lookups' do
    number_binding.routing_policy.update!(
      mode: 'reject',
      fallback_message: 'Rejected by bearer auth'
    )

    with_modified_env(TELEPHONY_BRIDGE_ACCESS_TOKEN: 'bridge-access-token') do
      post path,
           params: {
             call_ref: 'inbound-route-bearer',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15551236666'
           },
           headers: {
             'Authorization' => 'Bearer bridge-access-token'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'reject_route',
      'message' => 'Rejected by bearer auth'
    )
  end

  it 'fails closed with an executable reject decision when routing raises after authentication' do
    allow(Telephony::InboundRoutingService).to receive(:new)
      .and_raise(Telephony::Error.new(code: 'ROUTE_LOOKUP_FAILED', message: 'Route lookup failed', status: :bad_gateway))

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-error',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15551230002'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'ROUTE_LOOKUP_FAILED',
      'message' => 'Route lookup failed'
    )
  end

  it 'rejects operator-mode calls when the operator is disabled instead of app fallback' do
    agent_binding = create(
      :telephony_agent_binding,
      account: account,
      agent_aor: 'sip:1002@example.test',
      enabled: false
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      fallback_mode: 'app'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             callRef: 'inbound-route-2',
             ingressNumber: voice_channel.phone_number,
             callerNumber: '+15551238888'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('app_ref')
  end

  it 'rejects operator-mode calls when the operator is disabled instead of AI fallback' do
    agent_binding = create(
      :telephony_agent_binding,
      account: account,
      agent_aor: 'sip:1007@example.test',
      enabled: false
    )
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      ai_app_ref: 'ai-fallback-app-ref',
      fallback_mode: 'ai'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             callRef: 'inbound-route-ai-fallback',
             ingressNumber: voice_channel.phone_number,
             callerNumber: '+15551238889'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('app_ref')
  end

  it 'routes an existing pending voice conversation to AI when AI routing is enabled' do
    caller_number = '+15551230001'
    contact = create(:contact, account: account, phone_number: caller_number)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: caller_number)
    conversation = create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :pending
    )
    create(
      :telephony_call_session,
      account: account,
      inbox: voice_inbox,
      number_binding: number_binding,
      conversation: conversation,
      external_call_ref: 'bridge-call-pending',
      status: 'in_progress'
    )

    number_binding.routing_policy.update!(
      mode: 'ai',
      ai_app_ref: 'ai-status-aware-app-ref',
      operator_agent_aor: 'sip:status-aware-operator@example.test',
      fallback_mode: 'operator'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-status-pending',
             ingress_number: voice_channel.phone_number,
             caller_number: caller_number
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'ai',
      'app_ref' => 'ai-status-aware-app-ref',
      'reason' => 'pending_conversation_ai_route',
      'bridge_call_ref' => 'bridge-call-pending'
    )
  end

  it 'keeps a recent terminal bridge call ref for the AI runtime leg correlation' do
    caller_number = '+15550000002'
    contact = create(:contact, account: account, phone_number: caller_number)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: caller_number)
    conversation = create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :pending
    )
    create(
      :telephony_call_session,
      account: account,
      inbox: voice_inbox,
      number_binding: number_binding,
      conversation: conversation,
      external_call_ref: 'bridge-call-terminal-recent',
      status: 'cancelled',
      end_reason: 'voice_stream_ended_before_app_answer',
      created_at: 10.seconds.ago,
      updated_at: 9.seconds.ago
    )

    number_binding.routing_policy.update!(
      mode: 'ai',
      ai_app_ref: 'ai-status-aware-app-ref',
      operator_agent_aor: 'sip:status-aware-operator@example.test',
      fallback_mode: 'operator'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'runtime-app-leg-recent-terminal',
             ingress_number: voice_channel.phone_number,
             caller_number: caller_number,
             app_ref: 'ai-status-aware-app-ref'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'app',
      'reason' => 'recursive_runtime_app_ref',
      'bridge_call_ref' => 'bridge-call-terminal-recent'
    )
  end

  it 'does not route a pending conversation to AI when the primary routing mode remains operator' do
    caller_number = '+15551230003'
    contact = create(:contact, account: account, phone_number: caller_number)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: caller_number)
    create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :pending
    )

    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_aor: 'sip:status-aware-operator@example.test',
      ai_app_ref: 'ai-status-aware-app-ref',
      fallback_mode: 'ai'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-operator-primary-pending',
             ingress_number: voice_channel.phone_number,
             caller_number: caller_number
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('app_ref')
  end

  it 'does not route pending conversations to AI when operator mode has AI enabled only as fallback' do
    caller_number = '+15550000004'
    contact = create(:contact, account: account, phone_number: caller_number)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: caller_number)
    create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :pending
    )

    number_binding.routing_policy.update!(
      mode: 'operator',
      ai_enabled: true,
      ai_deployment_mode: 'onelink_managed',
      onelink_ai_app_ref: 'onelink-ai-status-aware-app-ref',
      operator_agent_aor: 'sip:status-aware-operator@example.test',
      fallback_mode: 'app'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-ai-enabled-operator-primary-pending',
             ingress_number: voice_channel.phone_number,
             caller_number: caller_number
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(number_binding.routing_policy.reload.ai_enabled).to be(true)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'operator_unavailable'
    )
    expect(response.parsed_body).not_to have_key('app_ref')
  end

  it 'routes an existing pending voice conversation to Captain AI using the managed app ref fallback' do
    caller_number = '+15550000005'
    contact = create(:contact, account: account, phone_number: caller_number)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: caller_number)
    assistant = create(:captain_assistant, account: account)
    conversation = create(
      :conversation,
      account: account,
      inbox: voice_inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :pending
    )
    create(
      :telephony_call_session,
      account: account,
      inbox: voice_inbox,
      number_binding: number_binding,
      conversation: conversation,
      external_call_ref: 'bridge-call-captain-operator-pending',
      status: 'in_progress'
    )

    number_binding.routing_policy.update!(
      mode: 'operator',
      ai_enabled: true,
      ai_deployment_mode: 'onelink_managed',
      captain_assistant: assistant,
      operator_agent_aor: 'sip:status-aware-operator@example.test',
      fallback_mode: 'app'
    )

    with_modified_env(
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret',
      ONELINK_AI_VOICE_APP_REF: 'onelink-captain-ai-status-aware-app-ref'
    ) do
      post path,
           params: {
             call_ref: 'inbound-route-captain-linked-operator-primary-pending',
             ingress_number: voice_channel.phone_number,
             caller_number: caller_number
           },
           headers: { 'X-Bridge-Secret' => 'bridge-secret' },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(number_binding.routing_policy.reload.onelink_ai_app_ref).to be_nil
    expect(response.parsed_body).to include(
      'action' => 'ai',
      'app_ref' => 'onelink-captain-ai-status-aware-app-ref',
      'reason' => 'pending_conversation_ai_route',
      'bridge_call_ref' => 'bridge-call-captain-operator-pending'
    )
  end

  it 'keeps AI-mode calls on AI for every existing non-pending voice conversation status' do
    agent_binding = create(
      :telephony_agent_binding,
      :registered,
      account: account,
      agent_aor: 'sip:status-aware-operator@example.test',
      enabled: true
    )
    number_binding.routing_policy.update!(
      mode: 'ai',
      ai_app_ref: 'ai-status-aware-app-ref',
      operator_agent_ref: agent_binding.agent_ref,
      operator_agent_aor: agent_binding.agent_aor,
      fallback_mode: 'operator'
    )

    %w[open resolved snoozed].each_with_index do |status, index|
      caller_number = "+1555123001#{index}"
      contact = create(:contact, account: account, phone_number: caller_number)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox, source_id: caller_number)
      create(
        :conversation,
        account: account,
        inbox: voice_inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        status: status
      )

      with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
        post path,
             params: {
               call_ref: "inbound-route-status-#{status}",
               ingress_number: voice_channel.phone_number,
               caller_number: caller_number
             },
             headers: {
               'X-Bridge-Secret' => 'bridge-secret'
             },
             as: :json
      end

      aggregate_failures(status) do
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include(
          'action' => 'ai',
          'app_ref' => 'ai-status-aware-app-ref',
          'reason' => 'ai_route'
        )
      end
    end
  end

  it 'routes AI calls to the OneLink-managed realtime voice app when that deployment mode is enabled' do
    number_binding.routing_policy.update!(
      mode: 'ai',
      ai_deployment_mode: 'onelink_managed',
      ai_app_ref: 'legacy-fonoster-ai-app',
      fonoster_ai_app_ref: 'legacy-fonoster-ai-app',
      onelink_ai_app_ref: 'onelink-ai-voice-app',
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-onelink-ai',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15557777777'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'ai',
      'ai_mode' => 'onelink_managed',
      'app_ref' => 'onelink-ai-voice-app',
      'reason' => 'ai_route',
      'number_ref' => number_binding.number_ref
    )
  end

  it 'keeps legacy Fonoster AI app ref as fallback when OneLink app ref is not configured' do
    number_binding.routing_policy.update!(
      mode: 'ai',
      ai_deployment_mode: 'onelink_managed',
      ai_app_ref: 'legacy-fonoster-ai-app',
      fonoster_ai_app_ref: 'legacy-fonoster-ai-app',
      onelink_ai_app_ref: nil,
      fallback_mode: 'reject'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-onelink-ai-fallback',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15557777778'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'ai',
      'app_ref' => 'legacy-fonoster-ai-app',
      'reason' => 'ai_route'
    )
  end

  it 'returns the out of office reject message when the inbox is closed' do
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_aor: 'sip:1003@example.test',
      fallback_mode: 'ai',
      ai_app_ref: 'out-of-office-ai-app',
      fallback_message: 'Fallback reject'
    )
    voice_inbox.update!(
      working_hours_enabled: true,
      out_of_office_message: 'We are closed now'
    )
    today_working_hour = voice_inbox.working_hours.find_by!(
      day_of_week: Time.zone.now.in_time_zone(voice_inbox.timezone).wday
    )
    today_working_hour.update!(
      closed_all_day: true,
      open_all_day: false,
      open_hour: nil,
      open_minutes: nil,
      close_hour: nil,
      close_minutes: nil
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-3',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15551237777'
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'message' => 'We are closed now',
      'reason' => 'out_of_office'
    )
    expect(response.parsed_body).not_to have_key('app_ref')
  end

  it 'rejects recursive runtime app routes instead of returning the ingress runtime app ref' do
    number_binding.routing_policy.update!(
      mode: 'app',
      fallback_mode: 'reject',
      fallback_message: 'Handled safely'
    )

    with_modified_env(TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret') do
      post path,
           params: {
             call_ref: 'inbound-route-recursive',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15551230099',
             app_ref: number_binding.configured_app_ref
           },
           headers: {
             'X-Bridge-Secret' => 'bridge-secret'
           },
           as: :json
    end

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include(
      'action' => 'reject',
      'reason' => 'recursive_runtime_app_ref',
      'message' => 'Handled safely'
    )
  end

  it 'writes inbound route request and response to the dedicated telephony debug log' do
    debug_log_file = Tempfile.new('telephony-route-debug')
    number_binding.routing_policy.update!(mode: 'app')

    with_modified_env(
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret',
      TELEPHONY_DEBUG_LOGGING: 'true',
      TELEPHONY_BRIDGE_DEBUG_LOG_PATH: debug_log_file.path
    ) do
      post path,
           params: {
             call_ref: 'inbound-route-log-1',
             ingress_number: voice_channel.phone_number,
             caller_number: '+15551234444'
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
        'event' => 'telephony_inbound_route_request',
        'path' => path,
        'call_ref' => 'inbound-route-log-1',
        'account_id' => account.id.to_s
      ),
      include(
        'event' => 'telephony_inbound_route_response',
        'path' => path,
        'call_ref' => 'inbound-route-log-1',
        'response_payload' => include('action' => 'app', 'app_ref' => number_binding.configured_app_ref)
      )
    )
  ensure
    debug_log_file&.close!
  end
end
