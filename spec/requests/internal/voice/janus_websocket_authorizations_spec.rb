require 'rails_helper'

RSpec.describe 'Internal Janus WebSocket authorization', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:channel) { create(:channel_voice, :sipuni, account: account) }
  let(:profile) do
    create(
      :telephony_sip_profile,
      account: account,
      inbox: channel.inbox,
      user: user,
      availability_mode: 'browser_webphone',
      status: 'active',
      enabled: true
    )
  end
  let(:server_url) { 'wss://app.one-link.kz/janus-sipuni' }
  let(:ticket) do
    Telephony::JanusWebsocketTicket.issue(
      server_url: server_url,
      account: account,
      user: user,
      sip_profile: profile
    )
  end
  let(:headers) do
    {
      'X-Janus-Ticket' => ticket,
      'X-Janus-Origin' => 'https://app.one-link.kz',
      'X-Janus-Path' => '/janus-sipuni'
    }
  end

  it 'authorizes a signed ticket supplied by the trusted reverse proxy' do
    get '/internal/voice/janus-ws/authorize', headers: headers

    expect(response).to have_http_status(:no_content)
  end

  it 'rejects replay of an already consumed ticket' do
    get '/internal/voice/janus-ws/authorize', headers: headers
    expect(response).to have_http_status(:no_content)

    get '/internal/voice/janus-ws/authorize', headers: headers
    expect(response).to have_http_status(:unauthorized)
  end

  it 'rejects requests without a signed ticket' do
    get '/internal/voice/janus-ws/authorize', headers: headers.except('X-Janus-Ticket')

    expect(response).to have_http_status(:unauthorized)
  end

  it 'rejects a ticket when the browser origin does not match' do
    get '/internal/voice/janus-ws/authorize', headers: headers.merge('X-Janus-Origin' => 'https://evil.example')

    expect(response).to have_http_status(:unauthorized)
  end
end
