require 'rails_helper'

RSpec.describe AccessControl::FutureTelephonyGrant do
  include FutureTelephonyGrantSpecHelper

  let(:account) { create(:account) }
  let(:roles) { AccessControl::SystemRoleBootstrapper.call(account: account).roles_by_key }

  before { simulate_bridge_catalog! }

  it 'ends the bridge-only tolerance once the native resource catalog owns Telephony' do
    expect(described_class.bridge_only?).to be(true)
    catalog = AccessRoleGrant::RESOURCE_CAPABILITIES.merge('telephony_calls' => %w[view view_reports])
    stub_const('AccessRoleGrant::RESOURCE_CAPABILITIES', catalog)
    expect(described_class.bridge_only?).to be(false)
  end

  it 'never seeds or advertises Telephony permissions in the bridge' do
    roles
    expect(AccessRoleGrant.where(resource: 'telephony_calls', account: account)).to be_empty
    expect(AccessRoleGrant::RESOURCE_CAPABILITIES).not_to have_key('telephony_calls')
    expect(AccessControl::SystemRoleCatalog::BOOTSTRAP_RESOURCES).not_to include('telephony_calls')
    account_user = create(:account_user, account: account, role: :agent)
    expect do
      AccessControl::ShadowResolver.call(account_user: account_user, resource: 'telephony_calls', capability: 'view')
    end.to raise_error(ArgumentError, /Unsupported resource/)
  end

  it 'preserves explicit opt-in and administrator none across repeated bootstrap without other-tenant impact' do
    administrator = roles.fetch('administrator')
    employee = roles.fetch('employee')
    admin_denial = insert_future_telephony_grant(role: administrator, scope: 'none')
    employee_view = insert_future_telephony_grant(role: employee, scope: 'own')
    employee_report = insert_future_telephony_grant(role: employee, capability: 'view_reports', scope: 'team')
    other_account = create(:account)
    AccessControl::SystemRoleBootstrapper.call(account: other_account)

    2.times { AccessControl::SystemRoleBootstrapper.call(account: account) }

    expect([admin_denial, employee_view, employee_report].map { |grant| grant.reload.access_scope }).to eq(%w[none own team])
    expect(AccessRoleGrant.where(resource: 'telephony_calls', account: account).count).to eq(3)
    expect(AccessRoleGrant.where(resource: 'telephony_calls', account: other_account)).to be_empty
  end

  it 'retains only existing future Telephony grants during legacy permission edits and repeated mapping' do
    custom_role = create(:custom_role, account: account, permissions: %w[crm_deal_view])
    mapped = AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
    future_view = insert_future_telephony_grant(role: mapped, scope: 'own')
    future_report = insert_future_telephony_grant(role: mapped, capability: 'view_reports', scope: 'team')

    custom_role.update!(permissions: %w[crm_task_view])
    AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
    AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)

    expect(mapped.grants.reload.pluck(:resource, :capability, :access_scope)).to contain_exactly(
      %w[tasks view all], %w[telephony_calls view own], %w[telephony_calls view_reports team]
    )
    expect(future_view.reload).to be_persisted
    expect(future_report.reload).to be_persisted
  end

  it 'matches assigned system/custom roles despite known future grants without accepting arbitrary drift' do
    admin = roles.fetch('administrator')
    admin_user = create(:account_user, account: account, role: :administrator)
    custom_role = create(:custom_role, account: account, permissions: %w[crm_task_view])
    mapped = AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
    custom_user = create(:account_user, account: account, role: :agent, custom_role: custom_role)
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    insert_future_telephony_grant(role: admin, scope: 'none')
    insert_future_telephony_grant(role: mapped, capability: 'view_reports', scope: 'own')
    expect([admin_user.reload.access_role_id, custom_user.reload.access_role_id]).to eq([admin.id, mapped.id])

    expect(AccessControl::LegacyCompatibilityChecker.call(account: account).counts).to eq('matched' => 2)
    expect(AccessControl::EnforcementReadiness.call(account: account)).to be_ready

    admin.grants.find_by!(resource: 'contacts', capability: 'view').update!(access_scope: 'own')
    result = AccessControl::EnforcementReadiness.call(account: account)
    expect(result).not_to be_ready
    expect(result.system_role_mismatches).to include('administrator')
    expect(result.compatibility_counts['mismatch']).to eq(1)
  end

  it 'fails readiness for an unknown future pair if a later schema permits it' do
    admin = roles.fetch('administrator')
    create(:account_user, account: account, role: :administrator)
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    connection = ActiveRecord::Base.connection
    constraint = connection.check_constraints(:access_role_grants).find do |entry|
      entry.name == 'access_role_grants_supported_resource_capability'
    end

    connection.transaction(requires_new: true) do
      connection.remove_check_constraint :access_role_grants, name: constraint.name
      invalid = insert_future_telephony_grant(role: admin, capability: 'configure', scope: 'none')
      expect(described_class.valid?(invalid)).to be(false)
      result = AccessControl::EnforcementReadiness.call(account: account)
      expect(result).not_to be_ready
      expect(result.system_role_mismatches).to include('administrator')
      expect(result.compatibility_counts['mismatch']).to eq(1)
      raise ActiveRecord::Rollback
    end
    expect(connection.check_constraints(:access_role_grants).map(&:name)).to include(constraint.name)
  end
end
