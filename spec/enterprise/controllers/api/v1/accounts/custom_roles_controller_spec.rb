require 'rails_helper'

RSpec.describe 'Custom Roles API', type: :request do
  include FutureTelephonyGrantSpecHelper

  let!(:account) { create(:account) }
  let!(:administrator) { create(:user, account: account, role: :administrator) }
  let!(:agent) { create(:user, account: account, role: :agent) }
  let!(:custom_role) { create(:custom_role, account: account, name: 'Manager') }

  describe 'GET #index' do
    context 'when it is an authenticated administrator' do
      it 'returns all custom roles in the account' do
        get "/api/v1/accounts/#{account.id}/custom_roles",
            headers: administrator.create_new_auth_token
        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body)

        expect(body[0]).to include('name' => custom_role.name)
      end
    end

    context 'when the user is an agent and is authenticated' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/custom_roles",
            headers: agent.create_new_auth_token

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/custom_roles"

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'GET #show' do
    context 'when it is an authenticated administrator' do
      it 'returns the custom role details' do
        get "/api/v1/accounts/#{account.id}/custom_roles/#{custom_role.id}",
            headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body)

        expect(body).to include('name' => custom_role.name)
      end
    end

    context 'when the user is an agent and is authenticated' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/custom_roles/#{custom_role.id}",
            headers: agent.create_new_auth_token

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/custom_roles/#{custom_role.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'POST #create' do
    let(:valid_params) do
      { custom_role: { name: 'Support', description: 'Support role',
                       permissions: CustomRole::PERMISSIONS.sample(SecureRandom.random_number(1..4)) } }
    end

    context 'when it is an authenticated administrator' do
      it 'creates the custom role' do
        expect do
          post "/api/v1/accounts/#{account.id}/custom_roles",
               params: valid_params,
               headers: administrator.create_new_auth_token
        end.to change(CustomRole, :count).by(1)

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body)

        expect(body).to include('name' => 'Support')
      end

      it 'materializes a supported role when the account is in shadow mode' do
        AccessControl::ModeTransition.call(account: account, to: :shadow)
        params = {
          custom_role: {
            name: 'Support',
            description: 'Support role',
            permissions: %w[crm_task_view]
          }
        }

        post "/api/v1/accounts/#{account.id}/custom_roles",
             params: params,
             headers: administrator.create_new_auth_token

        created_role = account.custom_roles.find(response.parsed_body.fetch('id'))
        expect(response).to have_http_status(:success)
        expect(created_role.access_role).to have_attributes(name: 'Support', description: 'Support role')
        expect(created_role.access_role.grants.pluck(:resource, :capability, :access_scope)).to eq(
          [%w[tasks view all]]
        )
      end
    end

    context 'when the user is an agent and is authenticated' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/custom_roles",
             params: valid_params,
             headers: agent.create_new_auth_token

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/custom_roles",
             params: valid_params

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'PUT #update' do
    let(:update_params) { { custom_role: { name: 'Updated Role' } } }

    context 'when it is an authenticated administrator' do
      it 'updates the custom role' do
        put "/api/v1/accounts/#{account.id}/custom_roles/#{custom_role.id}",
            params: update_params,
            headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body)

        expect(body).to include('name' => 'Updated Role')
      end

      it 'preserves future opt-in grants when the legacy permissions editor saves' do
        custom_role.update!(permissions: %w[crm_deal_view])
        mapped_role = AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
        grant = insert_future_telephony_grant(role: mapped_role, scope: 'own')

        put "/api/v1/accounts/#{account.id}/custom_roles/#{custom_role.id}",
            params: { custom_role: { name: 'Updated Role', permissions: %w[crm_task_view] } },
            headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(grant.reload.access_scope).to eq('own')
        expect(mapped_role.grants.reload.pluck(:resource, :capability, :access_scope)).to contain_exactly(
          %w[tasks view all], %w[telephony_calls view own]
        )
      end

      it 'updates an existing canonical role in the same request' do
        custom_role.update!(permissions: %w[crm_task_view])
        mapped_role = AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)

        put "/api/v1/accounts/#{account.id}/custom_roles/#{custom_role.id}",
            params: {
              custom_role: {
                name: 'Updated Role',
                description: 'Updated description',
                permissions: %w[crm_task_view]
              }
            },
            headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(mapped_role.reload).to have_attributes(name: 'Updated Role', description: 'Updated description')
        expect(mapped_role.grants.pluck(:resource, :capability, :access_scope)).to eq([%w[tasks view all]])
      end
    end

    context 'when the user is an agent and is authenticated' do
      it 'returns unauthorized' do
        put "/api/v1/accounts/#{account.id}/custom_roles/#{custom_role.id}",
            params: update_params,
            headers: agent.create_new_auth_token

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        put "/api/v1/accounts/#{account.id}/custom_roles/#{custom_role.id}",
            params: update_params

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'DELETE #destroy' do
    context 'when it is an authenticated administrator' do
      it 'deletes the custom role' do
        delete "/api/v1/accounts/#{account.id}/custom_roles/#{custom_role.id}",
               headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(CustomRole.count).to eq(0)
      end

      it 'deletes an unassigned canonical role with the custom role' do
        custom_role.update!(permissions: %w[crm_task_view])
        mapped_role = AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)

        delete "/api/v1/accounts/#{account.id}/custom_roles/#{custom_role.id}",
               headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(AccessRole.where(id: mapped_role.id)).not_to exist
      end

      it 'deprovisions future grants when the whole unassigned role is explicitly deleted' do
        custom_role.update!(permissions: %w[crm_task_view])
        mapped_role = AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
        future = insert_future_telephony_grant(role: mapped_role)

        delete "/api/v1/accounts/#{account.id}/custom_roles/#{custom_role.id}",
               headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(AccessRoleGrant.where(id: future.id)).not_to exist
      end

      it 'returns a diagnostic error when the canonical role is assigned to an account user' do
        custom_role.update!(permissions: %w[crm_task_view])
        mapped_role = AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
        grant_ids = mapped_role.grant_ids
        create(:account_user, account: account, access_role: mapped_role)

        delete "/api/v1/accounts/#{account.id}/custom_roles/#{custom_role.id}",
               headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.fetch('error')).to be_present
        expect(CustomRole.where(id: custom_role.id)).to exist
        expect(AccessRole.where(id: mapped_role.id)).to exist
        expect(AccessRoleGrant.where(id: grant_ids).count).to eq(grant_ids.size)
      end

      it 'returns a diagnostic error when the canonical role is referenced by a lifecycle snapshot' do
        custom_role.update!(permissions: %w[crm_task_view])
        mapped_role = AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
        grant_ids = mapped_role.grant_ids
        create(:account_user_lifecycle_snapshot, account: account, access_role: mapped_role)

        delete "/api/v1/accounts/#{account.id}/custom_roles/#{custom_role.id}",
               headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body.fetch('error')).to be_present
        expect(CustomRole.where(id: custom_role.id)).to exist
        expect(AccessRole.where(id: mapped_role.id)).to exist
        expect(AccessRoleGrant.where(id: grant_ids).count).to eq(grant_ids.size)
      end

      it 'rejects deletion while the role is assigned' do
        create(:account_user, account: account, custom_role: custom_role)

        delete "/api/v1/accounts/#{account.id}/custom_roles/#{custom_role.id}",
               headers: administrator.create_new_auth_token

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to be_present
        expect(CustomRole.where(id: custom_role.id)).to exist
      end
    end

    context 'when the user is an agent and is authenticated' do
      it 'returns unauthorized' do
        delete "/api/v1/accounts/#{account.id}/custom_roles/#{custom_role.id}",
               headers: agent.create_new_auth_token

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        delete "/api/v1/accounts/#{account.id}/custom_roles/#{custom_role.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  context 'when the account has completed a normalized role mutation' do
    before do
      account.update!(access_role_canonicalized_at: Time.current)
    end

    it 'rejects legacy API creation' do
      expect do
        post "/api/v1/accounts/#{account.id}/custom_roles",
             params: { custom_role: { name: 'Blocked role', permissions: %w[crm_task_view] } },
             headers: administrator.create_new_auth_token
      end.not_to change(CustomRole, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'rejects legacy API updates' do
      put "/api/v1/accounts/#{account.id}/custom_roles/#{custom_role.id}",
          params: { custom_role: { name: 'Blocked update' } },
          headers: administrator.create_new_auth_token

      expect(response).to have_http_status(:unprocessable_content)
      expect(custom_role.reload.name).to eq('Manager')
    end

    it 'rejects legacy API deletion' do
      delete "/api/v1/accounts/#{account.id}/custom_roles/#{custom_role.id}",
             headers: administrator.create_new_auth_token

      expect(response).to have_http_status(:unprocessable_content)
      expect(custom_role.reload).to be_persisted
    end
  end
end
