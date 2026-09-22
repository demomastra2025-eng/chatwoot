require 'rails_helper'

RSpec.describe AccessControl::SystemRoleBootstrapper do
  let(:account) { create(:account) }
  let(:roles) { described_class.call(account: account).roles_by_key }

  describe '.call' do
    it 'creates all system roles and their canonical grants' do
      result = described_class.call(account: account)

      expect(result.roles_by_key.keys).to match_array(AccessControl::SystemRoleCatalog::ROLE_NAMES.keys)
      expect(result.created_roles).to eq(5)
      expect(account.access_roles.where.not(system_key: nil).count).to eq(5)

      administrator = result.roles_by_key.fetch('administrator')
      expected_admin_grants = AccessControl::SystemRoleCatalog::BOOTSTRAP_RESOURCES.sum do |resource|
        AccessRoleGrant::RESOURCE_CAPABILITIES.fetch(resource).size
      end
      expect(administrator.grants.count).to eq(expected_admin_grants)
      expect(administrator.grants.distinct.pluck(:access_scope)).to eq(['all'])
      automation_grants = AccessRoleGrant.where(account: account, resource: 'automation_rules')
      expect(automation_grants.pluck(:access_role_id, :capability, :access_scope)).to eq([[administrator.id, 'manage', 'all']])

      observer = result.roles_by_key.fetch('observer')
      expected_observer_grants = AccessControl::SystemRoleCatalog::SCOPED_BOOTSTRAP_RESOURCES.map do |resource|
        [resource, 'view', 'all']
      end
      expect(observer.grants.pluck(:resource, :capability, :access_scope)).to match_array(expected_observer_grants)
    end

    it 'creates the canonical Department Lead matrix' do
      department_lead = roles.fetch('department_lead')
      expected_lead_grants = AccessControl::SystemRoleCatalog::SCOPED_BOOTSTRAP_RESOURCES.flat_map do |resource|
        capabilities = AccessRoleGrant::RESOURCE_CAPABILITIES.fetch(resource)
        allowed = capabilities.reject do |capability|
          %w[configure override_schedule].include?(capability) ||
            (resource == 'appointments' && capability == 'manage_finance')
        end
        allowed.map { |capability| [resource, capability, 'team'] }
      end
      expect(department_lead.grants.pluck(:resource, :capability, :access_scope)).to match_array(expected_lead_grants)
    end

    it 'creates the canonical Employee matrix' do
      employee = roles.fetch('employee')
      expected_employee_grants = AccessControl::SystemRoleCatalog::SCOPED_BOOTSTRAP_RESOURCES.flat_map do |resource|
        capabilities = AccessRoleGrant::RESOURCE_CAPABILITIES.fetch(resource)
        selected = capabilities.select do |capability|
          %w[view create update_fields assign transition take complete_cancel delete_archive].include?(capability)
        end
        selected.map do |capability|
          scope = if capability == 'view' && %w[contacts conversations appointments].include?(resource)
                    'all'
                  elsif resource == 'conversations' && capability == 'take'
                    'team'
                  else
                    'own'
                  end
          [resource, capability, scope]
        end
      end
      expect(employee.grants.pluck(:resource, :capability, :access_scope)).to match_array(expected_employee_grants)
    end

    it 'creates the canonical Commercial Director matrix' do
      commercial_director = roles.fetch('commercial_director')
      reporting_capabilities = %w[view export view_reports]
      expected_commercial_grants = AccessControl::SystemRoleCatalog::SCOPED_BOOTSTRAP_RESOURCES.flat_map do |resource|
        reporting_capabilities.map { |capability| [resource, capability, 'all'] }
      end
      expected_commercial_grants += %w[contacts deals tasks].flat_map do |resource|
        capabilities = AccessRoleGrant::RESOURCE_CAPABILITIES.fetch(resource)
        operational = capabilities.reject do |capability|
          %w[view view_configuration configure export view_reports].include?(capability)
        end
        operational.map { |capability| [resource, capability, 'all'] }
      end
      expect(commercial_director.grants.pluck(:resource, :capability, :access_scope)).to match_array(expected_commercial_grants)
    end

    it 'is idempotent and reconciles stale or extra grants' do
      first_result = described_class.call(account: account)
      employee = first_result.roles_by_key.fetch('employee')
      existing_grant = employee.grants.find_by!(resource: 'contacts', capability: 'view')
      existing_grant.update!(access_scope: 'team')
      extra_grant = employee.grants.create!(account: account, resource: 'contacts', capability: 'configure', access_scope: 'all')

      second_result = described_class.call(account: account)

      expect(second_result.created_roles).to eq(0)
      expect(second_result.created_grants).to eq(0)
      expect(existing_grant.reload.access_scope).to eq('all')
      expect(AccessRoleGrant.where(id: extra_grant.id)).not_to exist
    end
  end
end
