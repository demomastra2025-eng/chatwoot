require 'rails_helper'

RSpec.describe 'Telephony Readiness API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:voice_channel) { create(:channel_voice, :fonoster, account: account, phone_number: '+15551230000') }
  let(:voice_inbox) { voice_channel.inbox }
  let(:path) { "/api/v1/accounts/#{account.id}/telephony/resources/readiness" }

  before do
    account.enable_features!('channel_voice')
  end

  it 'returns ready when bridge health and Fonoster inbox setup are valid' do
    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      voice_inbox

      stub_request(:get, 'https://bridge.example/healthz')
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret' })
        .to_return(
          status: 200,
          body: {
            ok: true,
            service: 'telephony-bridge',
            fonoster: { applicationsReachable: true },
            legacyChatwootCompatibility: { configured: true }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      get path, headers: headers
    end

    expect(response).to have_http_status(:ok)

    payload = response.parsed_body['payload']
    expect(payload).to include('ready' => true, 'warnings' => [])
    expect(payload.fetch('bridge')).to include('healthy' => true)
    expect(payload.fetch('account')).to include(
      'fonoster_inboxes_count' => 1,
      'ready_inboxes_count' => 1
    )

    inbox = payload['inboxes'].first
    expect(inbox).to include(
      'id' => voice_inbox.id,
      'provider' => 'fonoster',
      'ready' => true,
      'number_binding_present' => true,
      'routing_policy_present' => true
    )
    expect(inbox['warnings']).to be_empty
  end

  it 'returns blocking warnings when the bridge is not configured and inbox binding is missing' do
    voice_inbox.telephony_number_binding.destroy!

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: nil,
      TELEPHONY_BRIDGE_SHARED_SECRET: nil
    ) do
      get path, headers: headers
    end

    expect(response).to have_http_status(:ok)

    payload = response.parsed_body['payload']
    expect(payload).to include('ready' => false)
    expect(payload.fetch('bridge')).to include(
      'configured' => false,
      'error_code' => 'BRIDGE_NOT_CONFIGURED'
    )

    warning_codes = payload['warnings'].map { |warning| warning['code'] }
    expect(warning_codes).to include('bridge_not_configured', 'inboxes_not_ready')

    inbox = payload['inboxes'].first
    expect(inbox).to include('ready' => false, 'number_binding_present' => false)
    expect(inbox['warnings'].map { |warning| warning['code'] }).to include('missing_number_binding')
  end

  it 'flags roadmap-only routing modes that degrade to bridge reject' do
    voice_inbox.telephony_number_binding.routing_policy.update!(
      mode: 'voicemail',
      fallback_message: 'Leave a voicemail'
    )

    with_modified_env(
      TELEPHONY_BRIDGE_BASE_URL: 'https://bridge.example',
      TELEPHONY_BRIDGE_SHARED_SECRET: 'bridge-secret'
    ) do
      stub_request(:get, 'https://bridge.example/healthz')
        .with(headers: { 'X-Bridge-Secret' => 'bridge-secret' })
        .to_return(
          status: 200,
          body: {
            ok: true,
            service: 'telephony-bridge',
            fonoster: { applicationsReachable: true },
            legacyChatwootCompatibility: { configured: true }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      get path, headers: headers
    end

    expect(response).to have_http_status(:ok)

    payload = response.parsed_body['payload']
    inbox = payload['inboxes'].first

    expect(payload).to include('ready' => false)
    expect(inbox).to include('ready' => false)
    expect(inbox.fetch('route')).to include('mode' => 'voicemail', 'bridge_mode' => 'reject')
    expect(inbox['warnings'].map { |warning| warning['code'] }).to include('bridge_mode_downgraded')
  end
end
