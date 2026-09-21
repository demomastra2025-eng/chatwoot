require 'rails_helper'

RSpec.describe 'Automation rule permissions', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:account_user) { agent.account_users.find_by!(account: account) }
  let(:path) { "/api/v1/accounts/#{account.id}/automation_rules" }

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

  it 'preserves administrator access in enforced mode before Automation grants can be bootstrapped' do
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

    expect(response).to have_http_status(:ok)
  end
end
