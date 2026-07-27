require 'rails_helper'

RSpec.describe 'Telephony Readiness API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:voice_channel) { create(:channel_voice, :sipuni, account: account, phone_number: '+15551230000') }
  let(:voice_inbox) { voice_channel.inbox }
  let(:path) { "/api/v1/accounts/#{account.id}/telephony/resources/readiness" }

  before do
    account.enable_features!('channel_voice')
  end

  it 'returns ready for local Janus SIP inbox setup' do
    voice_inbox

    get path, headers: headers

    expect(response).to have_http_status(:ok)

    payload = response.parsed_body.fetch('payload')
    expect(payload).to include('ready' => true, 'warnings' => [])
    expect(payload.fetch('janus_sip')).to include(
      'healthy' => true,
      'providers' => %w[asterisk_analog sipuni binotel beeline],
      'mode' => 'browser_webphone'
    )
    expect(payload.fetch('account')).to include(
      'janus_sip_inboxes_count' => 1,
      'ready_inboxes_count' => 1
    )

    inbox = payload.fetch('inboxes').first
    expect(inbox).to include(
      'id' => voice_inbox.id,
      'provider' => 'sipuni',
      'ready' => true,
      'number_binding_present' => true,
      'routing_policy_present' => true
    )
    expect(inbox.fetch('warnings')).to be_empty
  end

  it 'does not require a single operator target for broadcast operator routing' do
    voice_inbox.telephony_number_binding.routing_policy.update!(
      mode: 'operator',
      operator_agent_ref: nil,
      operator_agent_aor: nil,
      fallback_mode: 'operator',
      settings: { 'operator_distribution_mode' => 'broadcast' }
    )

    get path, headers: headers

    expect(response).to have_http_status(:ok)

    payload = response.parsed_body.fetch('payload')
    inbox = payload.fetch('inboxes').first
    warning_codes = inbox.fetch('warnings').map { |warning| warning['code'] }

    expect(payload).to include('ready' => true)
    expect(inbox).to include('ready' => true)
    expect(warning_codes).not_to include('mode_requires_operator_agent', 'fallback_requires_operator_agent')
  end

  it 'returns blocking warnings when inbox binding is missing' do
    voice_inbox.telephony_number_binding.destroy!

    get path, headers: headers

    expect(response).to have_http_status(:ok)

    payload = response.parsed_body.fetch('payload')
    expect(payload).to include('ready' => false)

    warning_codes = payload.fetch('warnings').map { |warning| warning['code'] }
    expect(warning_codes).to include('inboxes_not_ready')

    inbox = payload.fetch('inboxes').first
    expect(inbox).to include('ready' => false, 'number_binding_present' => false)
    expect(inbox.fetch('warnings').map { |warning| warning['code'] }).to include('missing_number_binding')
  end
end
