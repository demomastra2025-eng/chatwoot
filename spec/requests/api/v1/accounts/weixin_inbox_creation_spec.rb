require 'rails_helper'

RSpec.describe 'Weixin inbox creation', type: :request do
  let(:account) { create(:account, limits: { inboxes: 10, non_web_inboxes: 10 }) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  it 'creates a QR-first Weixin inbox from display_name without requiring top-level name' do
    expect do
      post "/api/v1/accounts/#{account.id}/inboxes",
           headers: admin.create_new_auth_token,
           params: { channel: { type: 'weixin', display_name: 'Main WeChat' } },
           as: :json
    end.to change(Channel::Weixin, :count).by(1)
                                          .and change(Inbox, :count).by(1)

    expect(response).to have_http_status(:success)
    expect(response.parsed_body['name']).to eq('Main WeChat')
    expect(response.parsed_body['channel_type']).to eq('Channel::Weixin')
  end

  it 'uses a default inbox name when Weixin display_name is omitted' do
    post "/api/v1/accounts/#{account.id}/inboxes",
         headers: admin.create_new_auth_token,
         params: { channel: { type: 'weixin' } },
         as: :json

    expect(response).to have_http_status(:success)
    expect(response.parsed_body['name']).to eq('Weixin Personal')
  end
end
