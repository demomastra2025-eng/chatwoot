require 'rails_helper'
require Rails.root.join('db/migrate/20260924120000_seed_telephony_call_report_administrator_grants')

RSpec.describe SeedTelephonyCallReportAdministratorGrants do
  subject(:migration) { described_class.new }

  let(:account) { create(:account) }
  let(:administrator) { create(:access_role, account: account, system_key: 'administrator') }
  let(:employee) { create(:access_role, account: account, system_key: 'employee') }

  it 'does not publish Telephony grants during db:chatwoot_prepare while old writers still run' do
    administrator
    migration.up

    expect(administrator.grants.where(resource: 'telephony_calls')).not_to exist
  end

  it 'seeds existing administrators only after cutover, without overwriting opt-ins or an explicit denial' do
    administrator.grants.create!(account: account, resource: 'telephony_calls', capability: 'view', access_scope: 'none')
    employee.grants.create!(account: account, resource: 'telephony_calls', capability: 'view_reports', access_scope: 'team')

    migration.up
    expect(administrator.grants.where(resource: 'telephony_calls').count).to eq(1)
    expect(AccessControl::TelephonyCallReportGrantSeeder.perform).to eq(1)
    expect(administrator.grants.where(resource: 'telephony_calls').pluck(:capability, :access_scope))
      .to contain_exactly(%w[view none], %w[view_reports all])
    expect(employee.grants.where(resource: 'telephony_calls').pluck(:capability, :access_scope))
      .to eq([%w[view_reports team]])

    expect(AccessControl::TelephonyCallReportGrantSeeder.perform).to eq(0)
    expect(administrator.grants.where(resource: 'telephony_calls').count).to eq(2)
    expect(administrator.grants.find_by!(resource: 'telephony_calls', capability: 'view').access_scope).to eq('none')
  end

  it 'rolls back to B without deleting grants or shrinking CHECKs' do
    administrator
    migration.up
    AccessControl::TelephonyCallReportGrantSeeder.perform
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
      expect { AccessControl::TelephonyCallReportGrantSeeder.perform }
        .to raise_error(/Bridge Telephony grant CHECK/)
      expect(administrator.grants.where(resource: 'telephony_calls')).not_to exist
      raise ActiveRecord::Rollback
    end
    expect(connection.check_constraints(:access_role_grants).map(&:name))
      .to include('access_role_grants_supported_resource')
  end

  it 'recovers roles bootstrapped by old code between preparation and cutover' do
    administrator
    migration.up
    new_account = create(:account)
    new_admin = create(:access_role, account: new_account, system_key: 'administrator')

    expect(AccessRoleGrant.where(resource: 'telephony_calls', account_id: [account.id, new_account.id])).not_to exist
    expect(AccessControl::TelephonyCallReportGrantSeeder.perform).to eq(4)
    expect([administrator, new_admin].map { |role| role.grants.where(resource: 'telephony_calls').count }).to eq([2, 2])
    expect(AccessControl::TelephonyCallReportGrantSeeder.perform).to eq(0)
  end

  it 'runs the seed through the idempotent release finalizer after cutover' do
    administrator
    migration.up
    allow(Inboxes::ConversationPolicyNormalizer).to receive(:perform).and_return(mismatches_after: 0)
    allow(Scheduling::ResourceTimezoneNormalizer).to receive(:perform).and_return(mismatches_after: 0)

    2.times do |attempt|
      inserted = attempt.zero? ? 2 : 0
      expect { load Rails.root.join('script/onelink/finalize_release.rb') }
        .to output(include(%("telephony_call_report_grants":{"status":"ok","inserted":#{inserted}}))).to_stdout
    end
    expect(administrator.grants.where(resource: 'telephony_calls').count).to eq(2)
  end
end
