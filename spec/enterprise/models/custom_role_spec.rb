require 'rails_helper'

RSpec.describe CustomRole, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to have_many(:account_users).dependent(:restrict_with_error) }
    it { is_expected.to have_one(:access_role).dependent(:restrict_with_error) }
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
