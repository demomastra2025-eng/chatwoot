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

      it 'assigns a canonical system role when the assignment gate is enabled' do
        enforce_access_control!(account)
        access_role = account.access_roles.find_by!(system_key: 'department_lead')

        ClimateControl.modify(ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'true') do
          post "/api/v1/accounts/#{account.id}/agents",
               headers: admin.create_new_auth_token,
               params: { email: 'lead@example.com', name: 'Lead', access_role_id: access_role.id },
               as: :json
        end

        account_user = User.find_by!(email: 'lead@example.com').account_users.find_by!(account: account)
        expect(response).to have_http_status(:success)
        expect(account_user).to have_attributes(role: 'agent', custom_role_id: nil, access_role_id: access_role.id)
        expect(account_user).not_to respond_to(:authorize_canonical_access_role_assignment)
        expect(JSON.parse(response.body)['access_role_id']).to eq(access_role.id)
      end

      it 'rolls back canonical creation while the assignment gate is disabled' do
        enforce_access_control!(account)
        access_role = account.access_roles.find_by!(system_key: 'department_lead')

        post "/api/v1/accounts/#{account.id}/agents",
             headers: admin.create_new_auth_token,
             params: { email: 'disabled@example.com', name: 'Disabled', access_role_id: access_role.id },
             as: :json

        expect(response).to have_http_status(:conflict)
        expect(JSON.parse(response.body)['code']).to eq('ACCESS_ROLE_ASSIGNMENTS_NOT_ENABLED')
        expect(User.from_email('disabled@example.com')).to be_nil
      end

      it 'rolls back canonical creation while access control is not enforced' do
        AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
        AccessControl::ModeTransition.call(account: account, to: :shadow)
        access_role = account.access_roles.find_by!(system_key: 'department_lead')

        ClimateControl.modify(ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'true') do
          post "/api/v1/accounts/#{account.id}/agents",
               headers: admin.create_new_auth_token,
               params: { email: 'shadow@example.com', name: 'Shadow', access_role_id: access_role.id },
               as: :json
        end

        expect(response).to have_http_status(:conflict)
        expect(JSON.parse(response.body)['code']).to eq('ACCESS_CONTROL_NOT_ENFORCED')
        expect(User.from_email('shadow@example.com')).to be_nil
      end

      it 'rejects ambiguous canonical and legacy assignment fields before creation' do
        enforce_access_control!(account)
        access_role = account.access_roles.find_by!(system_key: 'employee')

        ClimateControl.modify(ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'true') do
          post "/api/v1/accounts/#{account.id}/agents",
               headers: admin.create_new_auth_token,
               params: { email: 'ambiguous@example.com', name: 'Ambiguous', role: 'agent', access_role_id: access_role.id },
               as: :json
        end

        expect(response).to have_http_status(:conflict)
        expect(JSON.parse(response.body)['code']).to eq('AMBIGUOUS_ROLE_ASSIGNMENT')
        expect(User.from_email('ambiguous@example.com')).to be_nil
      end

      it 'rejects a canonical role owned by another account without creating the user' do
        enforce_access_control!(account)
        other_account = create(:account)
        enforce_access_control!(other_account)
        foreign_role = other_account.access_roles.find_by!(system_key: 'employee')

        ClimateControl.modify(ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'true') do
          post "/api/v1/accounts/#{account.id}/agents",
               headers: admin.create_new_auth_token,
               params: { email: 'foreign-role@example.com', name: 'Foreign', access_role_id: foreign_role.id },
               as: :json
        end

        expect(response).to have_http_status(:not_found)
        expect(User.from_email('foreign-role@example.com')).to be_nil
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

      it 'assigns a canonical role with optimistic previous-role protection' do
        enforce_access_control!(account)
        account_user = other_agent.account_users.first.reload
        previous_access_role_id = account_user.access_role_id
        access_role = account.access_roles.find_by!(system_key: 'observer')

        ClimateControl.modify(ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'true') do
          put "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}",
              headers: admin.create_new_auth_token,
              params: { access_role_id: access_role.id, previous_access_role_id: previous_access_role_id },
              as: :json
        end

        expect(response).to have_http_status(:success)
        expect(account_user.reload).to have_attributes(role: 'agent', custom_role_id: nil, access_role_id: access_role.id)
        expect(JSON.parse(response.body)['access_role_id']).to eq(access_role.id)
      end

      it 'assigns a canonical custom role and its legacy compatibility shell together' do
        canonical_role = AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
        enforce_access_control!(account)
        account_user = other_agent.account_users.first.reload

        ClimateControl.modify(ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'true') do
          put "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}",
              headers: admin.create_new_auth_token,
              params: {
                access_role_id: canonical_role.id,
                previous_access_role_id: account_user.access_role_id
              },
              as: :json
        end

        expect(response).to have_http_status(:success)
        expect(account_user.reload).to have_attributes(
          role: 'agent',
          custom_role_id: custom_role.id,
          access_role_id: canonical_role.id
        )
      end

      it 'requires an optimistic baseline for canonical updates' do
        enforce_access_control!(account)
        access_role = account.access_roles.find_by!(system_key: 'observer')

        ClimateControl.modify(ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'true') do
          put "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}",
              headers: admin.create_new_auth_token,
              params: { access_role_id: access_role.id },
              as: :json
        end

        expect(response).to have_http_status(:conflict)
        expect(JSON.parse(response.body)['code']).to eq('PREVIOUS_ACCESS_ROLE_ID_REQUIRED')
      end

      it 'rejects a stale canonical assignment without overwriting the newer role' do
        enforce_access_control!(account)
        account_user = other_agent.account_users.first.reload
        employee_role_id = account_user.access_role_id
        observer_role = account.access_roles.find_by!(system_key: 'observer')
        lead_role = account.access_roles.find_by!(system_key: 'department_lead')

        ClimateControl.modify(ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'true') do
          AccessControl::AccessRoleAssigner.assign(
            account: account,
            account_user: account_user,
            access_role_id: observer_role.id,
            expected_access_role_id: employee_role_id
          )
          put "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}",
              headers: admin.create_new_auth_token,
              params: { access_role_id: lead_role.id, previous_access_role_id: employee_role_id },
              as: :json
        end

        expect(response).to have_http_status(:conflict)
        expect(JSON.parse(response.body)['code']).to eq('STALE_ACCESS_ROLE_ASSIGNMENT')
        expect(account_user.reload.access_role).to eq(observer_role)
      end

      it 'treats a retry of an already applied canonical assignment as idempotent' do
        enforce_access_control!(account)
        account_user = other_agent.account_users.first.reload
        employee_role_id = account_user.access_role_id
        observer_role = account.access_roles.find_by!(system_key: 'observer')
        headers = admin.create_new_auth_token

        ClimateControl.modify(ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'true') do
          2.times do
            put "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}",
                headers: headers,
                params: { access_role_id: observer_role.id, previous_access_role_id: employee_role_id },
                as: :json
            expect(response).to have_http_status(:success)
          end
        end

        expect(account_user.reload.access_role).to eq(observer_role)
      end

      it 'allows unchanged legacy identity fields during an unrelated update after canonical rollout' do
        enforce_access_control!(account)
        account_user = other_agent.account_users.first.reload

        ClimateControl.modify(ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'true') do
          put "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}",
              headers: admin.create_new_auth_token,
              params: { name: 'Renamed', availability: 'busy', role: account_user.role, custom_role_id: account_user.custom_role_id },
              as: :json
        end

        expect(response).to have_http_status(:success)
        expect(account_user.reload).to have_attributes(availability: 'busy', access_role_id: account_user.access_role_id)
      end

      it 'rejects a legacy role change after canonical assignments are enabled' do
        enforce_access_control!(account)

        ClimateControl.modify(ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'true') do
          put "/api/v1/accounts/#{account.id}/agents/#{other_agent.id}",
              headers: admin.create_new_auth_token,
              params: { role: 'administrator' },
              as: :json
        end

        expect(response).to have_http_status(:conflict)
        expect(JSON.parse(response.body)['code']).to eq('LEGACY_ROLE_ASSIGNMENTS_DISABLED')
        expect(other_agent.account_users.first.reload).to be_agent
      end
    end
  end

  def enforce_access_control!(target_account)
    AccessControl::LegacyRoleAssigner.call(account: target_account, apply: true)
    AccessControl::ModeTransition.call(account: target_account, to: :shadow)
    AccessControl::ModeTransition.call(account: target_account, to: :enforced)
  end
end
