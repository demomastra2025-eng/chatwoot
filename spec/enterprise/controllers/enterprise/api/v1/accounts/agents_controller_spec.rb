require 'rails_helper'

RSpec.describe 'Enterprise Agents API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let!(:custom_role) { create(:custom_role, account: account, permissions: %w[crm_task_view]) }

  describe 'POST /api/v1/accounts/{account.id}/agents' do
    let(:params) { { email: 'test@example.com', name: 'Test User', role: 'agent', custom_role_id: custom_role.id } }

    context 'when it is an authenticated administrator' do
      it 'creates an agent with the specified custom role' do
        post "/api/v1/accounts/#{account.id}/agents", headers: admin.create_new_auth_token, params: params, as: :json

        expect(response).to have_http_status(:success)
        agent = account.agents.last
        expect(agent.account_users.first.custom_role_id).to eq(custom_role.id)
        expect(agent.account_users.first.access_role.legacy_custom_role_id).to eq(custom_role.id)
        expect(JSON.parse(response.body)['custom_role_id']).to eq(custom_role.id)
      end

      it 'keeps an unsupported custom role unassigned in the new model' do
        unsupported_role = create(:custom_role, account: account, permissions: %w[report_manage])

        post "/api/v1/accounts/#{account.id}/agents",
             headers: admin.create_new_auth_token,
             params: params.merge(custom_role_id: unsupported_role.id),
             as: :json

        account_user = User.find_by!(email: params[:email]).account_users.find_by!(account: account)
        expect(response).to have_http_status(:success)
        expect(account_user.custom_role).to eq(unsupported_role)
        expect(account_user.access_role).to be_nil
      end
    end
  end

  describe 'PUT /api/v1/accounts/{account.id}/agents/:id' do
    let(:other_agent) { create(:user, account: account, role: :agent) }

    context 'when it is an authenticated administrator' do
      it 'modified the custom role of the agent' do
        put "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}",
            headers: admin.create_new_auth_token,
            params: { custom_role_id: custom_role.id },
            as: :json

        expect(response).to have_http_status(:success)
        expect(other_agent.account_users.first.reload.custom_role_id).to eq(custom_role.id)
        expect(other_agent.account_users.first.access_role.legacy_custom_role_id).to eq(custom_role.id)
        expect(JSON.parse(response.body)['custom_role_id']).to eq(custom_role.id)
      end

      it 'clears a stale mapping after the same custom role becomes unsupported' do
        access_role = AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
        account_user = other_agent.account_users.first
        account_user.update!(custom_role: custom_role, access_role: access_role)
        custom_role.update!(permissions: %w[report_manage])

        put "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}",
            headers: admin.create_new_auth_token,
            params: { custom_role_id: custom_role.id },
            as: :json

        expect(response).to have_http_status(:success)
        expect(account_user.reload.custom_role).to eq(custom_role)
        expect(account_user.access_role).to be_nil
      end
    end
  end
end
