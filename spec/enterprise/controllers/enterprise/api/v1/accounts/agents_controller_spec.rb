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

      it 'creates a plain agent with a compatible AccessRole in enforced mode' do
        enforce_access_control!(account)
        plain_params = params.except(:custom_role_id).merge(email: 'plain-enforced@example.com')

        post "/api/v1/accounts/#{account.id}/agents", headers: admin.create_new_auth_token, params: plain_params, as: :json

        account_user = User.find_by!(email: plain_params[:email]).account_users.find_by!(account: account)
        expect(response).to have_http_status(:success)
        expect(account_user.access_role.system_key).to eq('employee')
      end

      it 'rolls back the user and account assignment for an unsupported custom role in enforced mode' do
        unsupported_role = create(:custom_role, account: account, permissions: %w[report_manage])
        enforce_access_control!(account)
        unsupported_params = params.merge(email: 'unsupported-enforced@example.com', custom_role_id: unsupported_role.id)

        post "/api/v1/accounts/#{account.id}/agents",
             headers: admin.create_new_auth_token,
             params: unsupported_params,
             as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(User.from_email(unsupported_params[:email])).to be_nil
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

      it 'preserves a plain agent AccessRole on an unrelated update in enforced mode' do
        account_user = other_agent.account_users.first
        enforce_access_control!(account)

        put "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}",
            headers: admin.create_new_auth_token,
            params: { name: 'Renamed agent', availability: 'online' },
            as: :json

        expect(response).to have_http_status(:success)
        expect(account_user.reload).to have_attributes(availability: 'online')
        expect(account_user.access_role.system_key).to eq('employee')
      end

      it 'reconciles AccessRole when custom role is explicitly cleared in enforced mode' do
        account_user = other_agent.account_users.first
        account_user.update!(custom_role: custom_role)
        enforce_access_control!(account)

        put "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}",
            headers: admin.create_new_auth_token,
            params: { custom_role_id: nil },
            as: :json

        expect(response).to have_http_status(:success)
        expect(account_user.reload.custom_role).to be_nil
        expect(account_user.access_role.system_key).to eq('employee')
      end
    end
  end

  def enforce_access_control!(target_account)
    AccessControl::LegacyRoleAssigner.call(account: target_account, apply: true)
    AccessControl::ModeTransition.call(account: target_account, to: :shadow)
    AccessControl::ModeTransition.call(account: target_account, to: :enforced)
  end
end
