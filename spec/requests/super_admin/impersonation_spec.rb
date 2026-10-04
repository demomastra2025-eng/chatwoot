# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe 'Super-admin impersonation session', type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:actor) { create(:super_admin) }
  let(:target) { create(:user, account: account, role: :administrator) }

  def begin_impersonation
    grant = SuperAdmin::ImpersonationService.issue_grant!(
      actor: actor, account: account, target_user: target
    )
    post '/auth/sign_in', params: { email: target.email, sso_auth_token: grant.token }, as: :json
    expect(response).to have_http_status(:success)
    [response.parsed_body.fetch('data'), response.headers.slice('access-token', 'client', 'uid')]
  end

  it 'keeps the customer desktop session active and limits profile membership to one account' do
    create(:account_user, account: other_account, user: target, role: :agent)
    permanent_api_token = target.access_token.token
    desktop_headers = target.create_new_auth_token
    get '/api/v1/profile', headers: desktop_headers, as: :json
    expect(response).to have_http_status(:success)
    desktop_client = desktop_headers.fetch('client')
    expect(target.reload).to be_active_auth_client(desktop_client)

    impersonation_payload, impersonation_headers = begin_impersonation

    expect(impersonation_payload).not_to include('access_token')
    expect(impersonation_payload['pubsub_token']).not_to eq(target.pubsub_token)
    expect(impersonation_payload['accounts'].map { |entry| entry['id'] }).to eq([account.id])
    expect(impersonation_headers['access-token']).not_to eq(permanent_api_token)
    expect(target.reload).to be_active_auth_client(desktop_client)
    expect(target.access_token.token).to eq(permanent_api_token)

    get '/api/v1/profile', headers: impersonation_headers, as: :json
    expect(response).to have_http_status(:success)
    expect(response.parsed_body).not_to include('access_token')
    expect(response.parsed_body['pubsub_token']).to eq(impersonation_payload['pubsub_token'])
    expect(response.parsed_body['accounts'].map { |entry| entry['id'] }).to eq([account.id])
    expect(response.parsed_body['account_id']).to eq(account.id)
    expect(response.parsed_body['role']).to eq('administrator')
  end

  it 'preserves permanent profile credentials for an ordinary customer session' do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with('CHATWOOT_INBOX_HMAC_KEY')
                                        .and_return('CHATWOOT_INBOX_HMAC_KEY' => 'synthetic-hmac-key')
    permanent_api_token = target.access_token.token
    headers = target.create_new_auth_token

    get '/api/v1/profile', headers: headers, as: :json

    expect(response).to have_http_status(:success)
    expect(response.parsed_body['access_token']).to eq(permanent_api_token)
    expect(response.parsed_body['pubsub_token']).to eq(target.pubsub_token)
    expect(response.parsed_body['hmac_identifier']).to eq(target.hmac_identifier)
  end

  it 'omits the permanent HMAC identity from an impersonated session' do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with('CHATWOOT_INBOX_HMAC_KEY')
                                        .and_return('CHATWOOT_INBOX_HMAC_KEY' => 'synthetic-hmac-key')
    login_payload, headers = begin_impersonation

    expect(login_payload).not_to include('hmac_identifier')

    get '/api/v1/profile', headers: headers, as: :json

    expect(response).to have_http_status(:success)
    expect(response.parsed_body).not_to include('hmac_identifier')
  end

  it 'denies another account, global profile mutation, and requests after expiry' do
    create(:account_user, account: other_account, user: target, role: :administrator)
    _login_payload, impersonation_headers = begin_impersonation

    get "/api/v1/accounts/#{other_account.id}", headers: impersonation_headers, as: :json
    expect(response).to have_http_status(:unauthorized)

    get "/api/v1/accounts/#{account.id}",
        headers: { 'HTTP_API_ACCESS_TOKEN' => impersonation_headers['access-token'] }, as: :json
    expect(response).to have_http_status(:unauthorized)

    original_name = target.name
    put '/api/v1/profile',
        params: { profile: { name: 'Impersonated name', password: 'NewPassword1!' } },
        headers: impersonation_headers, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(target.reload.name).to eq(original_name)

    put '/auth/password',
        params: { reset_password_token: 'untrusted', password: 'NewPassword1!', password_confirmation: 'NewPassword1!' },
        headers: impersonation_headers, as: :json
    expect(response).to have_http_status(:unauthorized)

    travel 16.minutes do
      get "/api/v1/accounts/#{account.id}", headers: impersonation_headers, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'allows only one concurrent redemption of a support SSO grant' do
    grant = SuperAdmin::ImpersonationService.issue_grant!(
      actor: actor, account: account, target_user: target
    )
    grant_payload = SuperAdmin::ImpersonationService.grant_for(user: target, token: grant.token)
    ready = Queue.new
    start = Queue.new
    threads = 2.times.map do
      Thread.new do
        ready << true
        start.pop
        SuperAdmin::ImpersonationService.consume_grant!(
          user: target, token: grant.token, grant: grant_payload
        )
      end
    end
    2.times { Timeout.timeout(5) { ready.pop } }
    2.times { start << true }
    results = threads.map { |thread| Timeout.timeout(5) { thread.value } }

    expect(results.count(true)).to eq(1)
    expect(results.count(false)).to eq(1)
  ensure
    2.times { start << true } if start
    threads&.each { |thread| thread.join(5) }
    SuperAdmin::ImpersonationService.revoke!(grant.client_id) if grant
  end

  it 'fails closed when a consumed support SSO grant is redeemed again' do
    permanent_headers = target.create_new_auth_token
    get '/api/v1/profile', headers: permanent_headers, as: :json
    grant = SuperAdmin::ImpersonationService.issue_grant!(
      actor: actor, account: account, target_user: target
    )
    params = { email: target.email, sso_auth_token: grant.token }

    post '/auth/sign_in', params: params, as: :json
    expect(response).to have_http_status(:success)
    support_headers = response.headers.slice('access-token', 'client', 'uid')
    get '/api/v1/profile', headers: support_headers, as: :json
    expect(response).to have_http_status(:success)
    expect(response.parsed_body['account_id']).to eq(account.id)

    post '/auth/sign_in', params: params, as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(target.reload).to be_active_auth_client(permanent_headers['client'])
  end

  it 'keeps capacity-policy user serializers within the support account scope' do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with('CHATWOOT_INBOX_HMAC_KEY')
                                        .and_return('CHATWOOT_INBOX_HMAC_KEY' => 'synthetic-hmac-key')
    colleague = create(:user, account: account, role: :administrator)
    policy = create(:agent_capacity_policy, account: account)
    [target, colleague].each do |user|
      create(:account_user, account: other_account, user: user, role: :administrator)
    end
    # Assign after creating the policy to avoid relying on factory defaults.
    [target, colleague].each do |user|
      user.account_users.find_by!(account_id: account.id).update!(agent_capacity_policy: policy)
    end
    _login_payload, headers = begin_impersonation

    get "/api/v1/accounts/#{account.id}/agent_capacity_policies/#{policy.id}/users",
        headers: headers, as: :json

    expect(response).to have_http_status(:success)
    response.parsed_body.each do |serialized_user|
      expect(serialized_user).not_to include('access_token', 'hmac_identifier')
      expect(serialized_user['pubsub_token']).to be_present
      expect(serialized_user['accounts'].map { |entry| entry['id'] }).to eq([account.id])
    end

    post "/api/v1/accounts/#{account.id}/agent_capacity_policies/#{policy.id}/users",
         params: { user_id: colleague.id }, headers: headers, as: :json

    expect(response).to have_http_status(:success)
    expect(response.parsed_body).not_to include('access_token', 'hmac_identifier')
    expect(response.parsed_body['accounts'].map { |entry| entry['id'] }).to eq([account.id])
  end

  it 'rejects collection account creation for support credentials even with injected account selectors' do
    _login_payload, headers = begin_impersonation
    captcha = instance_double(ChatwootCaptcha, valid?: true)
    allow(ChatwootCaptcha).to receive(:new).and_return(captcha)
    expect(AccountBuilder).not_to receive(:new)

    with_modified_env ENABLE_ACCOUNT_SIGNUP: 'true' do
      [{ account_id: account.id }, { id: account.id }].each do |selector|
        expect do
          post '/api/v1/accounts',
               params: {
                 account_name: 'Synthetic account',
                 user_full_name: 'Synthetic user',
                 email: 'synthetic-signup@example.test',
                 password: 'SafeSyntheticPassword1!',
                 **selector
               },
               headers: headers,
               as: :json
        end.not_to change(Account, :count)
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  it 'keeps token validation credentials scoped to the active support session' do
    create(:account_user, account: other_account, user: target, role: :agent)
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with('CHATWOOT_INBOX_HMAC_KEY')
                                        .and_return('CHATWOOT_INBOX_HMAC_KEY' => 'synthetic-hmac-key')
    login_payload, headers = begin_impersonation

    get '/auth/validate_token', headers: headers, as: :json

    expect(response).to have_http_status(:success)
    payload = response.parsed_body.fetch('payload').fetch('data')
    expect(payload).not_to include('access_token', 'hmac_identifier')
    expect(payload['pubsub_token']).to eq(login_payload['pubsub_token'])
    expect(payload['accounts'].map { |entry| entry['id'] }).to eq([account.id])
  end

  it 'keeps validate-token headers account-bound and expires them without credential fallback' do
    _login_payload, login_headers = begin_impersonation

    get '/auth/validate_token', headers: login_headers, as: :json

    expect(response).to have_http_status(:success)
    request_headers = login_headers.merge(response.headers.slice('access-token', 'client', 'uid'))
    expect(request_headers['client']).to eq(login_headers['client'])

    get "/api/v1/accounts/#{account.id}", headers: request_headers, as: :json
    expect(response).to have_http_status(:success)

    travel 16.minutes do
      get "/api/v1/accounts/#{account.id}", headers: request_headers, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'revokes the session when the acting super admin is removed' do
    _login_payload, impersonation_headers = begin_impersonation
    actor.destroy!

    get "/api/v1/accounts/#{account.id}", headers: impersonation_headers, as: :json

    expect(response).to have_http_status(:unauthorized)
  end
end
