require 'rails_helper'
require Rails.root.join('db/migrate/20260924113000_expand_telephony_call_grant_checks_for_compatibility')

RSpec.describe ExpandTelephonyCallGrantChecksForCompatibility do
  include FutureTelephonyGrantSpecHelper

  subject(:migration) { described_class.new }

  let(:account) { create(:account) }
  let(:role) { create(:access_role, account: account) }
  let(:connection) { ActiveRecord::Base.connection }

  it 'expands CHECKs with zero seed and leaves existing old combinations intact' do
    role
    before = AccessRoleGrant.where(resource: 'telephony_calls').count
    migration.up

    expect(AccessRoleGrant.where(resource: 'telephony_calls').count).to eq(before)
    expect(insert_future_telephony_grant(role: role, capability: 'view_reports', scope: 'team').reload.access_scope).to eq('team')
    expect(role.grants.create!(account: account, resource: 'appointments', capability: 'manage_finance', access_scope: 'own'))
      .to be_persisted
    expect(role.grants.create!(account: account, resource: 'automation_rules', capability: 'manage', access_scope: 'none'))
      .to be_persisted
  end

  it 'keeps the old DB restrictive and restores the same contract after a safe rollback' do
    role
    migration.down
    expect do
      AccessRoleGrant.transaction(requires_new: true) { insert_future_telephony_grant(role: role) }
    end.to raise_error(ActiveRecord::StatementInvalid, /access_role_grants_supported_resource/)

    migration.up
    insert_future_telephony_grant(role: role)
    expect(AccessRoleGrant.where(resource: 'telephony_calls', account: account).count).to eq(1)
  end

  it 'rejects wrong capability, wrong scope, and unknown resource at the database boundary' do
    role
    expect do
      AccessRoleGrant.transaction(requires_new: true) { insert_future_telephony_grant(role: role, capability: 'configure') }
    end.to raise_error(ActiveRecord::StatementInvalid, /access_role_grants_supported_resource_capability/)
    expect do
      AccessRoleGrant.transaction(requires_new: true) { insert_future_telephony_grant(role: role, scope: 'alien') }
    end.to raise_error(ActiveRecord::StatementInvalid, /access_role_grants_supported_scope/)
    expect do
      AccessRoleGrant.transaction(requires_new: true) do
        attributes = {
          account_id: account.id, access_role_id: role.id,
          resource: 'unrelated_future', capability: 'view', access_scope: 'all',
          created_at: Time.current, updated_at: Time.current
        }
        AccessRoleGrant.insert_all!([attributes]) # rubocop:disable Rails/SkipsModelValidations
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /access_role_grants_supported_resource/)
  end

  it 'refuses rollback after any future grant, including explicit none, without dropping constraints or rows' do
    grant = insert_future_telephony_grant(role: role, scope: 'none')
    original = constraints

    expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration, /minimum rollback floor/)
    expect(constraints).to eq(original)
    expect(grant.reload).to be_persisted
  end

  it 'rolls back the full DDL transaction when a new constraint cannot be installed' do
    role
    original = constraints
    allow(connection).to receive(:add_check_constraint).and_raise(StandardError, 'forced failure')

    connection.transaction(requires_new: true) do
      expect { migration.up }.to raise_error(StandardError, 'forced failure')
      raise ActiveRecord::Rollback
    end
    expect(constraints).to eq(original)
  end

  private

  def constraints
    connection.check_constraints(:access_role_grants).to_h { |constraint| [constraint.name, constraint.expression] }
  end
end
