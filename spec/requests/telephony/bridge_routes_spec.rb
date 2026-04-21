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
             caller_number: '+15551239999'
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
  end

  it 'returns a destination operator route for local operator targets' do
    number_binding.routing_policy.update!(
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
      'action' => 'operator',
      'destination' => 'operator1',
      'reason' => 'operator_route'
    )
    expect(response.parsed_body).not_to have_key('agent_aor')
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

  it 'falls back to the primary app when the operator is disabled' do
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
      'action' => 'app',
      'app_ref' => number_binding.configured_app_ref,
      'reason' => 'operator_unavailable'
    )
  end

  it 'falls back to ai when the operator is disabled and ai fallback is configured' do
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
      'action' => 'ai',
      'app_ref' => 'ai-fallback-app-ref',
      'reason' => 'operator_unavailable'
    )
  end

  it 'returns the out of office reject message when the inbox is closed' do
    number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_aor: 'sip:1003@example.test',
      fallback_mode: 'reject',
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
