require 'rails_helper'

RSpec.describe 'Automation rule permissions', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:account_user) { agent.account_users.find_by!(account: account) }
  let(:path) { "/api/v1/accounts/#{account.id}/automation_rules" }

  it 'authorizes every Automation mutation with a persisted grant in enforced mode' do
    enable_enforced_access!
    account_user.reload.access_role.grants.create!(
      account: account, resource: 'automation_rules', capability: 'manage', access_scope: 'all'
    )
    headers = agent.create_new_auth_token

    rule = create(:automation_rule, account: account)
    get path, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    get "#{path}/#{rule.id}", headers: headers, as: :json
    expect(response).to have_http_status(:ok)

    post path,
         params: {
           name: 'Persisted grant rule', event_name: 'conversation_updated',
           conditions: rule.conditions, actions: rule.actions
         },
         headers: headers,
         as: :json
    expect(response).to have_http_status(:success)

    patch "#{path}/#{rule.id}", params: { name: 'Updated through grant' }, headers: headers, as: :json
    expect(response).to have_http_status(:success)
    patch "#{path}/#{rule.id}", params: { active: false }, headers: headers, as: :json
    expect(response).to have_http_status(:success)
    post "#{path}/#{rule.id}/clone", headers: headers, as: :json
    expect(response).to have_http_status(:success)
    delete "#{path}/#{rule.id}", headers: headers, as: :json
    expect(response).to have_http_status(:ok)
  end

  it 'denies every Automation endpoint without the persisted grant in enforced mode' do
    enable_enforced_access!
    headers = agent.create_new_auth_token
    rule = create(:automation_rule, account: account)

    requests = [
      -> { get path, headers: headers, as: :json },
      -> { get "#{path}/#{rule.id}", headers: headers, as: :json },
      -> { post path, params: {}, headers: headers, as: :json },
      -> { patch "#{path}/#{rule.id}", params: { active: false }, headers: headers, as: :json },
      -> { post "#{path}/#{rule.id}/clone", headers: headers, as: :json },
      -> { delete "#{path}/#{rule.id}", headers: headers, as: :json }
    ]

    requests.each do |request|
      request.call
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it 'allows an agent with the explicit legacy permission' do
    custom_role = create(:custom_role, account: account, permissions: %w[automation_manage])
    account_user.update!(custom_role: custom_role)

    get path, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
  end

  it 'rejects deal and task managers without the Automation permission' do
    custom_role = create(:custom_role, account: account, permissions: %w[crm_deal_manage crm_task_manage])
    account_user.update!(custom_role: custom_role)

    get path, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it 'requires the administrator Automation grant in enforced mode after rollout' do
    administrator = create(:user, account: account, role: :administrator)
    administrator_account_user = administrator.account_users.find_by!(account: account)
    access_role_resolution = AccessControl::ShadowResolver::Result.new(
      account_user_id: administrator_account_user.id,
      access_role_id: administrator_account_user.access_role_id,
      resource: 'automation_rules',
      capability: 'manage',
      scope: 'none',
      status: 'resolved',
      reason: 'missing_grant'
    )
    mode_resolution = AccessControl::ModeResolver::Result.new(
      account_id: account.id,
      mode: 'enforced',
      authoritative_source: 'access_role',
      access_role_resolution: access_role_resolution
    )
    allow(AccessControl::ModeResolver).to receive(:call).and_return(mode_resolution)

    get path, headers: administrator.create_new_auth_token, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  def enable_enforced_access!
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end
end
