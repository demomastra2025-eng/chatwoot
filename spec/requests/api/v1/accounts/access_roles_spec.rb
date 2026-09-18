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
        'access_scopes' => AccessRoleGrant::ACCESS_SCOPES,
        'mutations_enabled' => false,
        'legacy_mutations_enabled' => true,
        'assignments_enabled' => false,
        'legacy_assignments_enabled' => true
      )
    end

    it 'does not advertise normalized mutations from the release gate alone' do
      ClimateControl.modify(ACCESS_ROLE_MUTATIONS_ENABLED: 'true') do
        get path, headers: administrator.create_new_auth_token, as: :json
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('meta', 'mutations_enabled')).to be(false)
      expect(response.parsed_body.dig('meta', 'legacy_mutations_enabled')).to be(true)
    end

    it 'advertises normalized mutations when the release gate and enforced mode are active' do
      enforce_access_control!

      ClimateControl.modify(ACCESS_ROLE_MUTATIONS_ENABLED: 'true') do
        get path, headers: administrator.create_new_auth_token, as: :json
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('meta', 'mutations_enabled')).to be(true)
      expect(response.parsed_body.dig('meta', 'legacy_mutations_enabled')).to be(false)
    end

    it 'does not advertise normalized assignments from the release gate alone' do
      ClimateControl.modify(ACCESS_ROLE_MUTATIONS_ENABLED: 'true', ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'true') do
        get path, headers: administrator.create_new_auth_token, as: :json
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('meta', 'assignments_enabled')).to be(false)
      expect(response.parsed_body.dig('meta', 'legacy_assignments_enabled')).to be(true)
    end

    it 'advertises normalized assignments when the release gate and enforced mode are active' do
      enforce_access_control!

      ClimateControl.modify(ACCESS_ROLE_MUTATIONS_ENABLED: 'true', ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'true') do
        get path, headers: administrator.create_new_auth_token, as: :json
      end

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('meta', 'assignments_enabled')).to be(true)
      expect(response.parsed_body.dig('meta', 'legacy_assignments_enabled')).to be(false)
    end

    it 'fails closed when assignments are enabled without mutations' do
      ClimateControl.modify(ACCESS_ROLE_MUTATIONS_ENABLED: 'false', ACCESS_ROLE_ASSIGNMENTS_ENABLED: 'true') do
        get path, headers: administrator.create_new_auth_token, as: :json
      end

      expect(response).to have_http_status(:internal_server_error)
    end

    it 'disables the legacy writer once a canonical role exists' do
      create(:access_role, account: account, grant_source: :canonical)

      get path, headers: administrator.create_new_auth_token, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('meta', 'legacy_mutations_enabled')).to be(false)
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

  describe 'normalized mutations' do
    around do |example|
      ClimateControl.modify(ACCESS_ROLE_MUTATIONS_ENABLED: 'true') { example.run }
    end

    it 'rejects mutations while the rolling-release gate is disabled' do
      enforce_access_control!

      ClimateControl.modify(ACCESS_ROLE_MUTATIONS_ENABLED: 'false') do
        expect do
          post api_v1_account_access_roles_url(account_id: account.id),
               params: { access_role: { name: 'Support', grants: [] } },
               headers: administrator.create_new_auth_token,
               as: :json
        end.not_to change(AccessRole, :count)
      end

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['code']).to eq('ACCESS_ROLE_MUTATIONS_NOT_ENABLED')
    end

    it 'creates a linked custom role with normalized grants in enforced mode' do
      enforce_access_control!

      post path,
           params: {
             access_role: {
               name: 'Clinic coordinator',
               description: 'Coordinates patient work',
               grants: [
                 { resource: 'contacts', capability: 'view', access_scope: 'team' },
                 { resource: 'tasks', capability: 'assign', access_scope: 'own' }
               ]
             }
           },
           headers: administrator.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:created)
      role = account.access_roles.find(response.parsed_body.dig('data', 'id'))
      expect(role).to have_attributes(name: 'Clinic coordinator', description: 'Coordinates patient work', system_key: nil)
      expect(role).to be_canonical_grant_source
      expect(role.legacy_custom_role).to have_attributes(name: 'Clinic coordinator', permissions: [])
      expect(account.reload.access_role_canonicalized_at).to be_present
      expect(serialized_grants(role)).to contain_exactly(
        %w[contacts view team],
        %w[tasks assign own]
      )
      expect(response.parsed_body.dig('data', 'lock_version')).to eq(role.lock_version)
    end

    it 'rejects normalized creation before access control is enforced' do
      administrator

      expect do
        post path,
             params: { access_role: { name: 'Support', grants: [] } },
             headers: administrator.create_new_auth_token,
             as: :json
      end.not_to change(AccessRole, :count)

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['code']).to eq('ACCESS_CONTROL_NOT_ENFORCED')
    end

    it 'does not record canonicalization when the first normalized creation rolls back' do
      enforce_access_control!

      post path,
           params: {
             access_role: {
               name: 'Broken role',
               grants: [{ resource: 'contacts', capability: 'complete_cancel', access_scope: 'all' }]
             }
           },
           headers: administrator.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(account.reload.access_role_canonicalized_at).to be_nil
      expect(account.access_roles.where(name: 'Broken role')).not_to exist
    end

    it 'atomically replaces metadata and grants without changing frozen legacy permissions' do
      enforce_access_control!
      role = create_normalized_role
      original_version = role.lock_version

      patch "#{path}/#{role.id}",
            params: {
              access_role: {
                name: 'Regional support',
                description: 'Updated description',
                lock_version: original_version,
                grants: [{ resource: 'deals', capability: 'update_fields', access_scope: 'all' }]
              }
            },
            headers: administrator.create_new_auth_token,
            as: :json

      expect(response).to have_http_status(:ok)
      expect(role.reload).to have_attributes(name: 'Regional support', description: 'Updated description')
      expect(role).to be_canonical_grant_source
      expect(role.lock_version).to be > original_version
      expect(role.legacy_custom_role).to have_attributes(name: 'Regional support', permissions: [])
      expect(serialized_grants(role)).to eq([%w[deals update_fields all]])
    end

    it 'rolls back metadata and grants when a replacement grant is invalid' do
      enforce_access_control!
      role = create_normalized_role
      original_attributes = role.attributes.slice('name', 'description', 'lock_version')
      original_grants = serialized_grants(role)

      patch "#{path}/#{role.id}",
            params: {
              access_role: {
                name: 'Broken update',
                lock_version: role.lock_version,
                grants: [{ resource: 'contacts', capability: 'complete_cancel', access_scope: 'all' }]
              }
            },
            headers: administrator.create_new_auth_token,
            as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(role.reload.attributes.slice('name', 'description', 'lock_version')).to eq(original_attributes)
      expect(role.legacy_custom_role.name).to eq(original_attributes.fetch('name'))
      expect(serialized_grants(role)).to eq(original_grants)
    end

    it 'rejects stale updates without overwriting the current role' do
      enforce_access_control!
      role = create_normalized_role
      stale_version = role.lock_version
      role.update!(description: 'Concurrent update')

      patch "#{path}/#{role.id}",
            params: { access_role: { description: 'Stale update', lock_version: stale_version } },
            headers: administrator.create_new_auth_token,
            as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['code']).to eq('STALE_ACCESS_ROLE')
      expect(role.reload.description).to eq('Concurrent update')
    end

    it 'does not claim grant ownership for an empty update' do
      enforce_access_control!
      custom_role = ClimateControl.modify(ACCESS_ROLE_MUTATIONS_ENABLED: 'false') do
        create(:custom_role, account: account, permissions: %w[crm_task_view])
      end
      role = custom_role.access_role

      patch "#{path}/#{role.id}",
            params: { access_role: { lock_version: role.lock_version } },
            headers: administrator.create_new_auth_token,
            as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['code']).to eq('MUTATION_REQUIRED')
      expect(role.reload).to be_legacy_grant_source
    end

    it 'rejects system role mutations' do
      enforce_access_control!
      role = account.access_roles.find_by!(system_key: 'employee')

      patch "#{path}/#{role.id}",
            params: { access_role: { name: 'Renamed employee', lock_version: role.lock_version } },
            headers: administrator.create_new_auth_token,
            as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['code']).to eq('SYSTEM_ROLE_IMMUTABLE')
      expect(role.reload.name).to eq('Employee')
    end

    it 'deletes an unassigned custom role and its legacy identity' do
      enforce_access_control!
      role = create_normalized_role
      custom_role_id = role.legacy_custom_role_id
      grant_ids = role.grant_ids

      delete "#{path}/#{role.id}",
             params: { access_role: { lock_version: role.lock_version } },
             headers: administrator.create_new_auth_token,
             as: :json

      expect(response).to have_http_status(:ok)
      expect(AccessRole.where(id: role.id)).not_to exist
      expect(CustomRole.where(id: custom_role_id)).not_to exist
      expect(AccessRoleGrant.where(id: grant_ids)).not_to exist
      expect(account.reload.access_role_canonicalized_at).to be_present
      ClimateControl.modify(ACCESS_ROLE_MUTATIONS_ENABLED: 'false') do
        expect(AccessControl::AccessRoleMutator.legacy_mutations_enabled_for?(account: account)).to be(false)
      end
    end

    it 'rejects deletion while the role is assigned and preserves both identities' do
      enforce_access_control!
      role = create_normalized_role
      create(:account_user, account: account, custom_role: role.legacy_custom_role, access_role: role)

      delete "#{path}/#{role.id}",
             params: { access_role: { lock_version: role.lock_version } },
             headers: administrator.create_new_auth_token,
             as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['message']).to be_present
      expect(role.reload).to be_persisted
      expect(role.legacy_custom_role.reload).to be_persisted
    end

    it 'does not expose a role from another account to mutation' do
      enforce_access_control!
      foreign_role = create(:access_role)

      patch "#{path}/#{foreign_role.id}",
            params: { access_role: { name: 'Cross-account update', lock_version: foreign_role.lock_version } },
            headers: administrator.create_new_auth_token,
            as: :json

      expect(response).to have_http_status(:not_found)
      expect(foreign_role.reload.name).not_to eq('Cross-account update')
    end

    it 'rejects normalized mutations from non-administrators' do
      enforce_access_control!

      post path,
           params: { access_role: { name: 'Support', grants: [] } },
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  def enforce_access_control!
    administrator
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
    account.reload
  end

  def create_normalized_role
    AccessControl::AccessRoleMutator.create(
      account: account,
      attributes: {
        'name' => 'Support',
        'description' => 'Initial description',
        'grants' => [{ 'resource' => 'tasks', 'capability' => 'view', 'access_scope' => 'team' }]
      }
    )
  end

  def serialized_grants(role)
    role.grants.reload.order(:resource, :capability).pluck(:resource, :capability, :access_scope)
  end
end
