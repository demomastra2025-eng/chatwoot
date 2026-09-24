require 'rails_helper'

RSpec.describe AccessControl::LegacyCustomRoleMapper do
  let(:account) { create(:account) }

  describe '.analyze' do
    it 'maps supported permissions and keeps the broadest duplicate scope' do
      custom_role = create(
        :custom_role,
        account: account,
        permissions: %w[conversation_team_manage conversation_manage crm_task_view automation_manage]
      )

      analysis = described_class.analyze(custom_role)

      expect(analysis).to be_mappable
      expect(analysis.grants).to include(
        { resource: 'conversations', capability: 'view', access_scope: 'all' },
        { resource: 'tasks', capability: 'view', access_scope: 'all' },
        { resource: 'automation_rules', capability: 'manage', access_scope: 'all' }
      )
      expect(analysis.grants).not_to include(
        { resource: 'conversations', capability: 'view', access_scope: 'team' }
      )
    end

    it 'reports permissions that cannot be represented safely' do
      custom_role = create(
        :custom_role,
        account: account,
        permissions: %w[contact_manage conversation_unassigned_manage scheduling_override]
      )

      analysis = described_class.analyze(custom_role)

      expect(analysis).not_to be_mappable
      expect(analysis.unsupported_permissions).to eq(%w[conversation_unassigned_manage scheduling_override])
    end
  end

  describe '.call' do
    it 'creates one idempotent access role for a supported custom role' do
      custom_role = create(:custom_role, account: account, name: 'Sales', permissions: %w[crm_deal_manage crm_task_view])

      role = described_class.call(custom_role: custom_role)
      repeated_role = described_class.call(custom_role: custom_role)

      expect(repeated_role).to eq(role)
      expect(role).to have_attributes(account_id: account.id, legacy_custom_role_id: custom_role.id, name: 'Sales')
      expect(role.grants.pluck(:resource, :capability, :access_scope)).to include(
        %w[deals transition all],
        %w[tasks view all]
      )
    end

    it 'refuses to materialize a partially supported role' do
      custom_role = create(:custom_role, account: account, permissions: %w[crm_task_view report_manage])

      expect { described_class.call(custom_role: custom_role) }
        .to raise_error(ArgumentError, 'Unsupported permissions: report_manage')
      expect(custom_role.reload.access_role).to be_nil
    end

    it 'reconciles grants after legacy permissions change' do
      custom_role = create(:custom_role, account: account, permissions: %w[crm_deal_manage])
      role = described_class.call(custom_role: custom_role)
      role.grants.find_by!(resource: 'deals', capability: 'view').update!(access_scope: 'team')
      extra_grant = role.grants.create!(account: account, resource: 'appointments', capability: 'view', access_scope: 'all')
      previous_version = role.lock_version
      custom_role.update_columns(permissions: %w[contact_manage]) # rubocop:disable Rails/SkipsModelValidations

      described_class.call(custom_role: custom_role)

      expect(role.reload.lock_version).to be > previous_version
      expect(role.grants.reload.pluck(:resource, :capability, :access_scope)).to match_array(
        %w[view create update_fields].map { |capability| ['contacts', capability, 'all'] }
      )
      expect(AccessRoleGrant.where(id: extra_grant.id)).not_to exist
    end

    it 'retains historical finance grants when reconciling current custom role grants' do
      custom_role = create(:custom_role, account: account, permissions: %w[crm_task_view])
      role = described_class.call(custom_role: custom_role)
      now = Time.current
      historical_grant = {
        account_id: account.id, access_role_id: role.id, resource: 'appointments',
        capability: 'view_finance', access_scope: 'all', created_at: now, updated_at: now
      }
      AccessRoleGrant.insert_all!([historical_grant]) # rubocop:disable Rails/SkipsModelValidations
      custom_role.update_columns(permissions: %w[contact_manage]) # rubocop:disable Rails/SkipsModelValidations

      described_class.call(custom_role: custom_role)

      expect(role.grants.where(resource: 'appointments', capability: 'view_finance')).to exist
      expect(role.grants.where(resource: 'contacts', capability: 'view')).to exist
      expect(role.grants.where(resource: 'tasks', capability: 'view')).not_to exist
    end

    it 'reconciles role metadata without treating its current name as a collision' do
      custom_role = create(
        :custom_role,
        account: account,
        name: 'Sales',
        description: 'Old description',
        permissions: %w[crm_task_view]
      )
      role = described_class.call(custom_role: custom_role)
      custom_role.update_columns(name: 'Support', description: 'New description') # rubocop:disable Rails/SkipsModelValidations

      described_class.call(custom_role: custom_role.reload)

      expect(role.reload).to have_attributes(name: 'Support', description: 'New description')
    end

    it 'reserves system role names before presets are materialized' do
      custom_role = create(:custom_role, account: account, name: 'Administrator', permissions: %w[crm_task_view])

      role = described_class.call(custom_role: custom_role)
      roles = AccessControl::SystemRoleBootstrapper.call(account: account).roles_by_key

      expect(role.name).to eq("Administrator (Imported #{custom_role.id})")
      expect(roles.fetch('administrator').name).to eq('Administrator')
    end

    it 'rolls back the role when grant reconciliation fails' do
      custom_role = create(:custom_role, account: account, permissions: %w[crm_task_view])
      allow(described_class).to receive(:reconcile_grants).and_raise(ActiveRecord::RecordInvalid)

      expect { described_class.call(custom_role: custom_role) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(custom_role.reload.access_role).to be_nil
    end
  end
end
