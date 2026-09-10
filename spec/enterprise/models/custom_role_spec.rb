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
end
