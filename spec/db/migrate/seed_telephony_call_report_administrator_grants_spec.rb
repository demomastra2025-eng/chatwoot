require 'rails_helper'
require Rails.root.join('db/migrate/20260924120000_seed_telephony_call_report_administrator_grants')

RSpec.describe SeedTelephonyCallReportAdministratorGrants do
  subject(:migration) { described_class.new }

  let(:account) { create(:account) }
  let(:administrator) { create(:access_role, account: account, system_key: 'administrator') }
  let(:employee) { create(:access_role, account: account, system_key: 'employee') }

  it 'seeds only existing administrators, without overwriting opt-ins or an explicit denial' do
    administrator.grants.create!(account: account, resource: 'telephony_calls', capability: 'view', access_scope: 'none')
    employee.grants.create!(account: account, resource: 'telephony_calls', capability: 'view_reports', access_scope: 'team')

    migration.up
    expect(administrator.grants.where(resource: 'telephony_calls').pluck(:capability, :access_scope))
      .to contain_exactly(%w[view none], %w[view_reports all])
    expect(employee.grants.where(resource: 'telephony_calls').pluck(:capability, :access_scope))
      .to eq([%w[view_reports team]])

    migration.up
    expect(administrator.grants.where(resource: 'telephony_calls').count).to eq(2)
    expect(administrator.grants.find_by!(resource: 'telephony_calls', capability: 'view').access_scope).to eq('none')
  end

  it 'rolls back to B without deleting grants or shrinking CHECKs' do
    administrator
    migration.up
    denied = administrator.grants.find_by!(resource: 'telephony_calls', capability: 'view_reports')
    denied.update!(access_scope: 'none')
    migration.down

    expect(denied.reload.access_scope).to eq('none')
    expect(administrator.grants.where(resource: 'telephony_calls').count).to eq(2)
    constraint = ActiveRecord::Base.connection.check_constraints(:access_role_grants).find do |entry|
      entry.name == 'access_role_grants_supported_resource'
    end
    expect(constraint.expression).to include('telephony_calls')
  end

  it 'fails before inserting if B constraint expansion is missing' do
    administrator
    connection = ActiveRecord::Base.connection
    connection.transaction(requires_new: true) do
      connection.remove_check_constraint :access_role_grants, name: 'access_role_grants_supported_resource'
      expect { migration.up }.to raise_error(ActiveRecord::MigrationError, /Bridge Telephony grant CHECK/)
      expect(administrator.grants.where(resource: 'telephony_calls')).not_to exist
      raise ActiveRecord::Rollback
    end
    expect(connection.check_constraints(:access_role_grants).map(&:name))
      .to include('access_role_grants_supported_resource')
  end
end
