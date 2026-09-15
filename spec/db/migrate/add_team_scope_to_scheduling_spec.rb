require 'rails_helper'
require Rails.root.join('db/migrate/20260914182000_add_team_scope_to_scheduling').to_s

RSpec.describe AddTeamScopeToScheduling do
  subject(:migration) { described_class.new }

  it 'idempotently backfills finance grants for existing system roles' do
    account = create(:account)
    AccessControl::SystemRoleBootstrapper.call(account: account)
    roles = account.access_roles.where.not(system_key: nil).index_by(&:system_key)
    AccessRoleGrant.where(
      access_role_id: roles.values.map(&:id),
      resource: 'appointments',
      capability: %w[view_finance manage_finance]
    ).delete_all

    2.times { migration.send(:backfill_system_role_finance_grants) }

    expect(finance_grants(roles.fetch('administrator'))).to eq(
      'manage_finance' => 'all',
      'view_finance' => 'all'
    )
    expect(finance_grants(roles.fetch('department_lead'))).to eq('view_finance' => 'team')
    expect(finance_grants(roles.fetch('employee'))).to eq({})
  end

  def finance_grants(role)
    role.grants
        .where(resource: 'appointments', capability: %w[view_finance manage_finance])
        .order(:capability)
        .pluck(:capability, :access_scope)
        .to_h
  end
end
