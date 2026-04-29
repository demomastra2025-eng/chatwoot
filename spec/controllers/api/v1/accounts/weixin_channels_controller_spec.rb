require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::WeixinChannelsController', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  describe 'POST /api/v1/accounts/:account_id/inboxes/:id/weixin_request_qr' do
    it 'returns an unprocessable response when the gateway is not configured' do
      channel = Channel::Weixin.create!(account: account, display_name: 'Pending QR Login')
      inbox = create(:inbox, account: account, channel: channel)

      with_modified_env('WEIXIN_GATEWAY_URL' => nil, 'WEIXIN_GATEWAY_TOKEN' => nil) do
        post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/weixin_request_qr",
             headers: admin.create_new_auth_token,
             as: :json
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('WEIXIN_GATEWAY_URL')
    end

    it 'stores QR-issued iLink credentials without exposing secrets in the inbox response' do
      channel = Channel::Weixin.create!(account: account, display_name: 'Pending QR Login')
      inbox = create(:inbox, account: account, channel: channel)

      gateway_result = {
        channel: {
          connection_state: 'connected',
          lifecycle_state: 'connected',
          ilink_token: 'qr-issued-token',
          provider_account_id: 'wxid_qr_bot',
          display_name: 'QR Bot',
          last_error: nil,
          runtime_state: { qr_login_state: 'confirmed', poller_state: 'running' }
        }
      }
      gateway_client = instance_double(
        Weixin::GatewayClient,
        sync_channel!: {},
        request_qr_login!: gateway_result
      )
      allow(Weixin::GatewayClient).to receive(:new).and_return(gateway_client)

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
