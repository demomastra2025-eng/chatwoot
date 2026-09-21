require 'rails_helper'
require Rails.root.join('db/migrate/20260921170300_add_automation_manage_access_role_grant')

RSpec.describe AddAutomationManageAccessRoleGrant do
  subject(:migration) { described_class.new }

  let(:account) { create(:account) }
  let(:role) { create(:access_role, account: account) }
  let(:connection) { ActiveRecord::Base.connection }
  let(:timestamps) { { created_at: Time.current, updated_at: Time.current } }

  around do |example|
    migration.up
    example.run
  ensure
    migration.up
  end

  it 'persists only none or all Automation management grants at the database boundary' do
    all_grant = role.grants.create!(
      account: account,
      resource: 'automation_rules',
      capability: 'manage',
      access_scope: 'all'
    )
    expect(all_grant.reload).to be_persisted

    none_role = create(:access_role, account: account)
    none_grant = none_role.grants.create!(
      account: account,
      resource: 'automation_rules',
      capability: 'manage',
      access_scope: 'none'
    )
    expect(none_grant.reload).to be_persisted

    expect do
      AccessRoleGrant.transaction(requires_new: true) do
        AccessRoleGrant.insert_all!([automation_grant_attributes(access_scope: 'team')]) # rubocop:disable Rails/SkipsModelValidations
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /access_role_grants_supported_resource_capability/)
  end

  it 'rejects Automation grants before up and permits them after up' do
    role
    migration.down

    expect do
      AccessRoleGrant.transaction(requires_new: true) do
        AccessRoleGrant.insert_all!([automation_grant_attributes(access_scope: 'all')]) # rubocop:disable Rails/SkipsModelValidations
      end
    end.to raise_error(ActiveRecord::StatementInvalid)

    migration.up

    expect do
      AccessRoleGrant.insert_all!([automation_grant_attributes(access_scope: 'all')]) # rubocop:disable Rails/SkipsModelValidations
    end.to change(AccessRoleGrant.where(resource: 'automation_rules', capability: 'manage'), :count).by(1)
  end

  it 'restores every previous grant constraint on rollback without removing existing grants' do
    existing_grant = role.grants.create!(
      account: account,
      resource: 'appointments',
      capability: 'manage_finance',
      access_scope: 'team'
    )
    role.grants.create!(account: account, resource: 'automation_rules', capability: 'manage', access_scope: 'all')

    migration.down

    expect(existing_grant.reload).to be_persisted
    expect(role.grants.where(resource: 'automation_rules')).not_to exist
    expect(constraint_expression('access_role_grants_supported_resource')).not_to include('automation_rules')
    expect(constraint_expression('access_role_grants_supported_capability')).not_to include("'manage'::character varying")
    expect(constraint_expression('access_role_grants_supported_resource_capability')).not_to include('automation_rules')
  end

  it 'backfills and reconciles the canonical administrator grant' do
    administrator = create(:access_role, account: account, system_key: 'administrator')

    migration.up

    grant = administrator.grants.find_by!(resource: 'automation_rules', capability: 'manage')
    expect(grant.access_scope).to eq('all')

    grant.update!(access_scope: 'none')
    migration.up

    expect(grant.reload.access_scope).to eq('all')
  end

  private

  def automation_grant_attributes(access_scope:)
    {
      account_id: account.id,
      access_role_id: role.id,
      resource: 'automation_rules',
      capability: 'manage',
      access_scope: access_scope,
      **timestamps
    }
  end

  def constraint_expression(name)
    connection.check_constraints(:access_role_grants).find { |constraint| constraint.name == name }.expression
  end
end
