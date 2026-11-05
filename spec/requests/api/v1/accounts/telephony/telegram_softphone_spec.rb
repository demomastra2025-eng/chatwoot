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
    account.enable_features!(:telegram_calls_bot)
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

  it 'denies show, link and online while OFF without creating a binding or invoking SIP' do
    account.disable_features!(:telegram_calls_bot)

    expect do
      get "/api/v1/accounts/#{account.id}/telephony/telegram_softphone", headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
      post "/api/v1/accounts/#{account.id}/telephony/telegram_softphone/link_token", headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
      patch "/api/v1/accounts/#{account.id}/telephony/telegram_softphone",
            params: { on_line: true }, headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
    end.not_to change(Telephony::TelegramOperatorBinding, :count)
    expect(sync_service).not_to have_received(:activate!)
  end

  it 'allows offline lease cleanup and disconnect after access is removed' do
    binding = Telephony::TelegramOperatorBinding.create!(
      account: account, user: agent, telegram_user_id: '601001', telegram_chat_id: '601001',
      verified_at: Time.current, on_line: true,
      sip_lease_meta: { 'group_key' => 'disabled-group', 'lines' => [{ 'release_key' => 'synthetic-release' }] }
    )
    account.disable_features!(:telegram_calls_bot)

    patch "/api/v1/accounts/#{account.id}/telephony/telegram_softphone",
          params: { on_line: false }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(binding.reload).not_to be_on_line
    expect(binding.sip_lease_meta).to eq({})
    expect(sync_service).to have_received(:deactivate!)

    delete "/api/v1/accounts/#{account.id}/telephony/telegram_softphone", headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(binding.reload.telegram_user_id).to be_nil
    expect(sync_service).not_to have_received(:activate!)
  end
end
