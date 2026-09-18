require 'rails_helper'

RSpec.describe 'Access Roles API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:path) { "/api/v1/accounts/#{account.id}/access_roles" }

  before do
    AccessControl::SystemRoleBootstrapper.call(account: account)
  end

  describe 'GET #index' do
    it 'returns the account-scoped canonical role catalog to administrators' do
      custom_role = create(
        :custom_role,
        account: account,
        name: 'Clinic coordinator',
        permissions: %w[contact_manage crm_task_view]
      )
      mapped_role = AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
      agent.account_users.find_by!(account_id: account.id).update!(custom_role: custom_role)

      foreign_account = create(:account)
      AccessControl::SystemRoleBootstrapper.call(account: foreign_account)

      get path, headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:ok)
      payload = response.parsed_body
      roles = payload.fetch('data')
      serialized_role = roles.find { |role| role['id'] == mapped_role.id }

      expect(roles.map { |role| role['id'] }).to match_array(account.access_role_ids)
      expect(serialized_role).to include(
        'name' => 'Clinic coordinator',
        'role_kind' => 'custom',
        'system_key' => nil,
        'legacy_custom_role_id' => custom_role.id,
        'assigned_users_count' => 1
      )
      expect(serialized_role.fetch('grants')).to include(
        'resource' => 'contacts',
        'capability' => 'view',
        'access_scope' => 'all'
      )
      expect(payload.fetch('meta')).to eq(
        'resources' => AccessRoleGrant::RESOURCE_CAPABILITIES,
        'access_scopes' => AccessRoleGrant::ACCESS_SCOPES
      )
    end

    it 'returns system role identity and zero assignment counts' do
      get path, headers: administrator.create_new_auth_token, as: :json

      employee_role = response.parsed_body.fetch('data').find { |role| role['system_key'] == 'employee' }

      expect(response).to have_http_status(:ok)
      expect(employee_role).to include(
        'name' => 'Employee',
        'role_kind' => 'system',
        'legacy_custom_role_id' => nil,
        'assigned_users_count' => 0
      )
      expect(employee_role.fetch('grants')).to be_present
    end

    it 'preloads grants for the whole catalog in one query' do
      account.access_roles.each do |access_role|
        next if access_role.grants.exists?(resource: 'contacts', capability: 'export')

        create(
          :access_role_grant,
          account: account,
          access_role: access_role,
          resource: 'contacts',
          capability: 'export',
          access_scope: 'none'
        )
      end
      grant_queries = []
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        sql = payload[:sql].to_s
        grant_queries << sql if sql.include?('FROM "access_role_grants"')
      end

      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        get path, headers: administrator.create_new_auth_token, as: :json
      end

      expect(response).to have_http_status(:ok)
      expect(grant_queries.size).to eq(1)
    end

    it 'rejects non-administrators' do
      get path, headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects unauthenticated requests' do
      get path, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
