require 'rails_helper'

RSpec.describe 'Inbox list with a missing channel record', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let!(:healthy_inbox) { create(:inbox, account: account) }
  let!(:orphan_inbox) do
    channel = create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
    inbox = channel.inbox
    Channel::Whatsapp.where(id: channel.id).delete_all
    inbox
  end

  before do
    create(:inbox_member, user: agent, inbox: healthy_inbox)
    create(:inbox_member, user: agent, inbox: orphan_inbox)
  end

  it 'still lists every inbox for an administrator and marks the broken one' do
    get "/api/v1/accounts/#{account.id}/inboxes", headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:success)
    payload = response.parsed_body['payload']
    expect(payload.pluck('id')).to include(healthy_inbox.id, orphan_inbox.id)
    broken = payload.find { |inbox| inbox['id'] == orphan_inbox.id }
    expect(broken['channel_missing']).to be(true)
    expect(broken['callback_webhook_url']).to be_nil
    expect(payload.find { |inbox| inbox['id'] == healthy_inbox.id }['channel_missing']).to be(false)
  end

  it 'still lists inboxes for an agent' do
    get "/api/v1/accounts/#{account.id}/inboxes", headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:success)
    expect(response.parsed_body['payload'].pluck('id')).to include(healthy_inbox.id, orphan_inbox.id)
  end
end
