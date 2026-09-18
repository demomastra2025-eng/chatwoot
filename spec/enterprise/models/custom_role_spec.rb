require 'rails_helper'

RSpec.describe CustomRole, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to have_many(:account_users).dependent(:restrict_with_error) }
    it { is_expected.to have_one(:access_role) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:name) }
  end

  it 'cannot be destroyed while assigned to an account user' do
    custom_role = create(:custom_role)
    create(:account_user, account: custom_role.account, custom_role: custom_role)

    expect { custom_role.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
  end

  it 'cannot be destroyed while referenced by an inactive user snapshot' do
    custom_role = create(:custom_role)
    create(
      :account_user_lifecycle_snapshot,
      account: custom_role.account,
      custom_role: custom_role
    )

    expect { custom_role.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
  end

  it 'does not materialize a new role while the account remains in legacy mode' do
    custom_role = create(:custom_role, permissions: %w[crm_task_view])

    expect(custom_role.access_role).to be_nil
  end

  it 'materializes a supported new role in shadow mode' do
    account = create(:account)
    AccessControl::ModeTransition.call(account: account, to: :shadow)

    custom_role = create(
      :custom_role,
      account: account,
      name: 'Support',
      description: 'Handles customer requests',
      permissions: %w[crm_task_view]
    )

    expect(custom_role.access_role).to have_attributes(
      name: 'Support',
      description: 'Handles customer requests'
    )
    expect(custom_role.access_role.grants.pluck(:resource, :capability, :access_scope)).to eq(
      [%w[tasks view all]]
    )
  end

  it 'rolls back shadow creation when canonical grant reconciliation fails' do
    account = create(:account)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    allow(AccessControl::LegacyCustomRoleMapper).to receive(:reconcile_grants).and_raise(
      ActiveRecord::RecordInvalid
    )

    expect do
      create(:custom_role, account: account, name: 'Support', permissions: %w[crm_task_view])
    end.to raise_error(ActiveRecord::RecordInvalid)

    expect(account.custom_roles.where(name: 'Support')).not_to exist
    expect(account.access_roles.where(name: 'Support')).not_to exist
  end

  it 'reconciles a materialized mapping after a representable permission change' do
    account = create(:account)
    AccessControl::SystemRoleBootstrapper.call(account: account)
    custom_role = create(:custom_role, account: account, permissions: %w[crm_task_view])
    expect(custom_role.access_role).to be_nil
    mapped_role = AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)

    custom_role.update!(permissions: %w[contact_manage])

    expect(mapped_role.grants.reload.pluck(:resource).uniq).to eq(%w[contacts])
  end

  it 'reconciles materialized role metadata in legacy mode' do
    custom_role = create(:custom_role, name: 'Sales', description: 'Old description', permissions: %w[crm_task_view])
    mapped_role = AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)

    custom_role.update!(name: 'Support', description: 'New description')

    expect(mapped_role.reload).to have_attributes(name: 'Support', description: 'New description')
  end

  it 'rolls back legacy and canonical changes when grant reconciliation fails' do
    custom_role = create(:custom_role, name: 'Sales', permissions: %w[crm_task_view])
    mapped_role = AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
    allow(AccessControl::LegacyCustomRoleMapper).to receive(:reconcile_grants).and_raise(
      ActiveRecord::RecordInvalid.new(mapped_role)
    )

    expect do
      custom_role.update!(name: 'Support', permissions: %w[contact_manage])
    end.to raise_error(ActiveRecord::RecordInvalid)

    expect(custom_role.reload).to have_attributes(name: 'Sales', permissions: %w[crm_task_view])
    expect(mapped_role.reload.name).to eq('Sales')
    expect(mapped_role.grants.pluck(:resource).uniq).to eq(%w[tasks])
  end

  it 'destroys an unassigned materialized role and its grants atomically' do
    custom_role = create(:custom_role, permissions: %w[crm_task_view])
    expect(custom_role.access_role).to be_nil
    mapped_role = AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
    grant_ids = mapped_role.grant_ids

    custom_role.destroy!

    expect(AccessRole.where(id: mapped_role.id)).not_to exist
    expect(AccessRoleGrant.where(id: grant_ids)).not_to exist
  end

  it 'cannot destroy a role while its canonical identity is assigned' do
    custom_role = create(:custom_role, permissions: %w[crm_task_view])
    mapped_role = AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
    create(:account_user, account: custom_role.account, access_role: mapped_role)

    expect { custom_role.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect(custom_role.reload).to be_persisted
    expect(mapped_role.reload).to be_persisted
  end

  it 'rejects permissions that cannot be represented in enforced mode' do
    account = create(:account)
    AccessControl::SystemRoleBootstrapper.call(account: account)
    custom_role = create(:custom_role, account: account, permissions: %w[crm_task_view])
    AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)

    expect(custom_role.update(permissions: %w[report_manage])).to be(false)
    expect(custom_role.errors[:permissions]).to include('must be representable while access control is enforced')
    expect(custom_role.reload.permissions).to eq(%w[crm_task_view])
  end
end
