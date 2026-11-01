require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Telephony::TelegramSoftphone', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { agent.create_new_auth_token }
  let(:sync_service) do
    instance_double(
      TelegramCalls::SipLineSyncService,
      activate!: { synced_lines: 0 },
      deactivate!: { deactivated: true }
    )
  end

  before do
    account.disable_features!(:channel_voice)
    allow(TelegramCalls::Config).to receive_messages(
      bot_token: '123456:TEST_BOT_TOKEN',
      bot_username: 'onelink_calls_bot',
      gateway_url: 'http://gateway.internal:8790',
      gateway_token: 'gw-secret'
    )
    allow(TelegramCalls::SipLineSyncService).to receive(:new).and_return(sync_service)
  end

  it 'returns unlinked status and issues link_token even without channel_voice feature' do
    get "/api/v1/accounts/#{account.id}/telephony/telegram_softphone",
        headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'configured')).to be(true)
    expect(response.parsed_body.dig('payload', 'connected')).to be(false)

    post "/api/v1/accounts/#{account.id}/telephony/telegram_softphone/link_token",
         headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'token')).to be_present
  end

  it 'toggles on_line and disconnects linked binding' do
    binding = Telephony::TelegramOperatorBinding.create!(
      account: account, user: agent, telegram_user_id: '601001',
      telegram_chat_id: '601001', username: 'agent_tg', verified_at: Time.current
    )

    patch "/api/v1/accounts/#{account.id}/telephony/telegram_softphone",
          params: { on_line: true },
          headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'on_line')).to be(true)
    expect(binding.reload).to be_on_line

    delete "/api/v1/accounts/#{account.id}/telephony/telegram_softphone",
           headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'connected')).to be(false)
  end
end
