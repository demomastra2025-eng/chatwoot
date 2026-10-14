require 'rails_helper'

RSpec.describe 'Workspace inbox membership API', type: :request do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:path) { "/api/v1/accounts/#{account.id}/inbox_members" }
  let(:headers) { admin.create_new_auth_token }

  it 'requires authentication and administrator access for writes' do
    channel = inbox
    patch path, as: :json, params: { inbox_id: channel.id, user_ids: [] }
    expect(response).to have_http_status(:unauthorized)

    patch path, headers: agent.create_new_auth_token, as: :json,
                params: { inbox_id: channel.id, user_ids: [] }
    expect(response).to have_http_status(:unauthorized)
  end

  it 'returns every workspace employee for a channel' do
    channel = inbox
    staff = agent
    administrator = admin

    get "#{path}/#{channel.id}", headers: headers

    expect(response).to have_http_status(:success)
    expect(response.parsed_body.fetch('payload').pluck('id')).to contain_exactly(staff.id, administrator.id)
  end

  it 'keeps all workspace employees when an old client submits a partial selection' do
    channel = inbox
    staff = agent
    administrator = admin
    existing_ids = channel.inbox_members.ids

    patch path, headers: headers, as: :json,
                params: { inbox_id: channel.id, user_ids: [staff.id] }

    expect(response).to have_http_status(:success)
    expect(channel.reload.members.ids).to contain_exactly(staff.id, administrator.id)
    expect(channel.inbox_members.ids).to match_array(existing_ids)
  end

  it 'accepts a legacy removal request without removing workspace membership' do
    channel = inbox
    staff = agent
    administrator = admin

    delete path, headers: headers, as: :json,
                 params: { inbox_id: channel.id, user_ids: [staff.id] }

    expect(response).to have_http_status(:success)
    expect(channel.reload.members.ids).to contain_exactly(staff.id, administrator.id)
  end

  it 'keeps repeated POST requests idempotent with string user IDs' do
    channel = inbox
    staff = agent
    administrator = admin
    existing_ids = channel.inbox_members.ids
    request_headers = headers

    2.times do
      post path, headers: request_headers, as: :json,
                 params: { inbox_id: channel.id, user_ids: [staff.id.to_s, administrator.id.to_s] }
      expect(response).to have_http_status(:success)
      expect(channel.reload.inbox_members.ids).to match_array(existing_ids)
      request_headers = request_headers.merge(response.headers.slice('access-token', 'client', 'uid'))
    end
  end

  it 'rejects invalid POST user IDs without changing membership' do
    channel = inbox
    staff = agent
    admin
    existing_ids = channel.inbox_members.ids

    post path, headers: headers, as: :json,
               params: { inbox_id: channel.id, user_ids: ["#{staff.id}invalid"] }

    expect(response).to have_http_status(:unprocessable_content)
    expect(channel.reload.inbox_members.ids).to match_array(existing_ids)
  end

  it 'rejects POST from an agent and unknown channels' do
    channel = inbox
    staff = agent

    post path, headers: staff.create_new_auth_token, as: :json,
               params: { inbox_id: channel.id, user_ids: [staff.id] }
    expect(response).to have_http_status(:unauthorized)

    post path, headers: headers, as: :json,
               params: { inbox_id: 0, user_ids: [staff.id] }
    expect(response).to have_http_status(:not_found)
  end

  it 'returns not found for unknown channels on PATCH and DELETE' do
    patch path, headers: headers, as: :json,
                params: { inbox_id: 0, user_ids: [] }
    expect(response).to have_http_status(:not_found)

    delete path, headers: headers.merge(response.headers.slice('access-token', 'client', 'uid')), as: :json,
                 params: { inbox_id: 0, user_ids: [] }
    expect(response).to have_http_status(:not_found)
  end
end
