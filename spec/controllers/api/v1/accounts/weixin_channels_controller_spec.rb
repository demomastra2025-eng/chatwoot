require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::WeixinChannelsController', type: :request do
  before do
    allow_any_instance_of(AccountUser).to receive(:create_notification_setting)
  end

  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  describe 'POST /api/v1/accounts/:account_id/inboxes/:id/weixin_request_qr' do
    it 'stores QR-issued iLink credentials without exposing secrets in the inbox response' do
      channel = Channel::Weixin.create!(account: account, display_name: 'Pending QR Login')
      inbox = create(:inbox, account: account, channel: channel)

      allow_any_instance_of(Weixin::GatewayClient).to receive(:sync_channel!).and_return({})
      allow_any_instance_of(Weixin::GatewayClient).to receive(:request_qr_login!).and_return(
        channel: {
          connection_state: 'connected',
          lifecycle_state: 'connected',
          ilink_token: 'qr-issued-token',
          provider_account_id: 'wxid_qr_bot',
          display_name: 'QR Bot',
          last_error: nil,
          runtime_state: { qr_login_state: 'confirmed', poller_state: 'running' }
        }
      )

      post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/weixin_request_qr",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(channel.reload.ilink_token).to eq('qr-issued-token')
      expect(channel.token_fingerprint).to eq(Digest::SHA256.hexdigest('qr-issued-token'))
      expect(channel.provider_account_id).to eq('wxid_qr_bot')
      expect(response.parsed_body['lifecycle_state']).to eq('connected')
      expect(response.parsed_body.dig('runtime_state', 'qr_login_state')).to eq('confirmed')
      expect(response.body).not_to include('qr-issued-token')
    end
  end
end
