require 'rails_helper'

RSpec.describe 'Internal Janus authorization for Telegram operator SIP', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:connection) { create(:telephony_provider_connection, account: account, provider_kind: 'sipuni', host: 'sip.example.test') }
  let(:channel) do
    create(:channel_voice, :sipuni, account: account,
                                    provider_config: { provider_kind: 'sipuni', provider_connection_id: connection.id,
                                                       number_ref: 'synthetic-operator-line' })
  end
  let(:profile) do
    create(:telephony_sip_profile, account: account, user: user, inbox: channel.inbox, provider_connection: connection,
                                   sip_password: 'synthetic-password', availability_mode: 'browser_webphone', status: 'active')
  end
  let(:binding) do
    Telephony::TelegramOperatorBinding.create!(account: account, user: user, telegram_user_id: '900000002',
                                               telegram_chat_id: '900000002', verified_at: Time.current, on_line: false)
  end
  let(:server_url) { 'wss://app.example.test/janus-sipuni' }
  let(:service) { Telephony::WebphoneService.new(account: account) }

  before do
    account.enable_features!(:channel_voice)
    profile
    create(:inbox_member, inbox: channel.inbox, user: user)
  end

  def extract_ticket(payload)
    sessions = payload[:webphone_sessions] || payload['webphone_sessions'] || [payload]
    url = sessions.first[:janus_server] || sessions.first['janus_server']
    URI.decode_www_form(URI.parse(url).query).to_h.fetch('janus_ticket')
  end

  def token_from(method, **params)
    with_modified_env(TELEPHONY_SIPUNI_JANUS_WS_URL: server_url, TELEPHONY_JANUS_WS_URL: server_url) do
      service.public_send(method, **params)
    end
  end

  def authorize(ticket, origin: nil)
    headers = { 'X-Janus-Ticket' => ticket, 'X-Janus-Path' => '/janus-sipuni' }
    headers['X-Janus-Origin'] = origin unless origin.nil?
    get '/internal/voice/janus-ws/authorize', headers: headers
  end

  it 'reproduces the native missing-Origin401 with a browser ticket then accepts the trusted server kind' do
    browser = extract_ticket(token_from(:token_for, user: user, client_instance_id: "telegram_softphone:#{binding.id}",
                                                    browser_instance_id: "telegram_softphone:#{user.id}", lease_mode: 'takeover'))
    authorize(browser)
    expect(response).to have_http_status(:unauthorized)

    headless = extract_ticket(token_from(:token_for_telegram_operator, binding: binding))
    expect(binding.reload.on_line?).to be(false)
    authorize(headless)
    expect(response).to have_http_status(:no_content)
    authorize(headless)
    expect(response).to have_http_status(:unauthorized)
  end

  it 'refuses a present Origin for the server kind and preserves strict browser Origin afterwards' do
    headless = extract_ticket(token_from(:token_for_telegram_operator, binding: binding))
    authorize(headless, origin: 'https://app.example.test')
    expect(response).to have_http_status(:unauthorized)
    browser = extract_ticket(token_from(:token_for, user: user, client_instance_id: 'browser-tab', lease_mode: 'takeover'))
    authorize(browser)
    expect(response).to have_http_status(:unauthorized)
    authorize(browser, origin: 'https://wrong.example.test')
    expect(response).to have_http_status(:unauthorized)
    authorize(browser, origin: 'https://app.example.test')
    expect(response).to have_http_status(:no_content)
  end

  it 'does not issue the server kind from browser controller parameters or operator-looking instance IDs' do
    params = {
      inbox_id: channel.inbox.id, client_instance_id: "telegram_softphone:#{binding.id}",
      browser_instance_id: "telegram_softphone:#{user.id}", lease_mode: 'takeover',
      kind: 'telegram_operator_sip', version: 3, binding_id: binding.id
    }
    with_modified_env(TELEPHONY_SIPUNI_JANUS_WS_URL: server_url, TELEPHONY_JANUS_WS_URL: server_url) do
      post "/api/v1/accounts/#{account.id}/telephony/webphone/token", headers: user.create_new_auth_token,
                                                                      params: params, as: :json
    end
    expect(response).to have_http_status(:ok)
    ticket = extract_ticket(response.parsed_body.fetch('payload'))
    payload = Telephony::JanusWebsocketTicket.send(:verified_payload, ticket)
    expect(payload['version']).to eq(1)
    expect(payload['kind']).to be_nil
    authorize(ticket)
    expect(response).to have_http_status(:unauthorized)
  end

  it 'clears the server scope when token issuance raises before reusing the same service for a browser' do
    allow(service).to receive(:token_for).and_raise(RuntimeError, 'synthetic token failure')
    expect { token_from(:token_for_telegram_operator, binding: binding) }.to raise_error(RuntimeError, 'synthetic token failure')
    allow(service).to receive(:token_for).and_call_original

    browser = extract_ticket(token_from(:token_for, user: user, client_instance_id: 'browser-after-failure', lease_mode: 'takeover'))
    payload = Telephony::JanusWebsocketTicket.send(:verified_payload, browser)
    expect(payload['version']).to eq(1)
    expect(payload['kind']).to be_nil
    authorize(browser)
    expect(response).to have_http_status(:unauthorized)
    authorize(browser, origin: 'https://app.example.test')
    expect(response).to have_http_status(:no_content)
  end
end
