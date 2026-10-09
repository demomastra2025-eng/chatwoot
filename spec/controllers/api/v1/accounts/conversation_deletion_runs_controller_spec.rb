require 'rails_helper'

RSpec.describe 'Conversation deletion receipts', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:conversation) { create(:conversation, account: account) }
  let(:key) { SecureRandom.uuid }
  let!(:run) do
    Conversations::DeletionService.new(account: account, user: user).create(
      conversations: [conversation], request_key: key, conversation_ids: [conversation.display_id]
    )
  end

  it 'looks up a lost response by key without enqueueing or changing the receipt' do
    receipt = run.reload.attributes
    expect do
      get "/api/v1/accounts/#{account.id}/bulk_action_runs", headers: user.create_new_auth_token,
          params: { request_key: key }, as: :json
    end.not_to have_enqueued_job(Conversations::DeletionJob)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'id')).to eq(run.id)
    expect(run.reload.attributes).to eq(receipt)
    expect(Conversation.exists?(conversation.id)).to be(true)
  end

  it 'does not reveal another employee receipt by ID or key' do
    other_user = create(:user, account: account, role: :administrator)
    headers = other_user.create_new_auth_token
    get "/api/v1/accounts/#{account.id}/bulk_action_runs/#{run.id}", headers: headers, as: :json
    expect(response).to have_http_status(:not_found)
    get "/api/v1/accounts/#{account.id}/bulk_action_runs", headers: headers, params: { request_key: key }, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it 'does not reveal the receipt in another account with the same employee' do
    other_account = create(:account)
    create(:account_user, account: other_account, user: user, role: :administrator)
    get "/api/v1/accounts/#{other_account.id}/bulk_action_runs/#{run.id}", headers: user.create_new_auth_token, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it 'rejects a reused UUID for a different target before submitting another job' do
    other = create(:conversation, account: account)
    expect do
      delete "/api/v1/accounts/#{account.id}/conversations/#{other.display_id}", headers: user.create_new_auth_token,
             params: { request_key: key }, as: :json
    end.not_to have_enqueued_job(Conversations::DeletionJob)
    expect(response).to have_http_status(:conflict)
    expect(Conversation.exists?(other.id)).to be(true)
  end

  it 'rejects unsafe IDs and invalid UUID before attempting destructive enrollment' do
    get "/api/v1/accounts/#{account.id}/bulk_action_runs/1e2", headers: user.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    delete "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}", headers: user.create_new_auth_token,
           params: { request_key: '' }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    delete "/api/v1/accounts/#{account.id}/conversations/1e2", headers: user.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end
end
