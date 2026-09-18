require 'rails_helper'

RSpec.describe AccessRole do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:legacy_custom_role).class_name('CustomRole').optional }
    it { is_expected.to have_many(:grants).class_name('AccessRoleGrant').dependent(:destroy) }
    it { is_expected.to have_many(:account_users).dependent(:restrict_with_error) }
  end

  describe 'validations' do
    subject(:access_role) { build(:access_role) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_uniqueness_of(:name).scoped_to(:account_id).case_insensitive }
    it { is_expected.to validate_inclusion_of(:system_key).in_array(described_class::SYSTEM_KEYS).allow_nil }

    it 'rejects unsupported grant ownership values' do
      expect { access_role.grant_source = 'unsupported' }.to raise_error(ArgumentError, /not a valid grant_source/)
    end

    it 'rejects a legacy custom role from another account' do
      access_role.legacy_custom_role = create(:custom_role)

      expect(access_role).not_to be_valid
      expect(access_role.errors[:legacy_custom_role]).to include('must belong to the same account')
    end

    it 'does not allow a legacy custom role on a system role' do
      access_role.legacy_custom_role = create(:custom_role, account: access_role.account)
      access_role.system_key = 'employee'

      expect(access_role).not_to be_valid
      expect(access_role.errors[:legacy_custom_role]).to include('cannot be combined with a system role')
    end

    it 'enforces a single identity source at the database boundary' do
      account = create(:account)
      custom_role = create(:custom_role, account: account)
      attributes = {
        account_id: account.id,
        name: 'Invalid dual identity role',
        system_key: 'employee',
        legacy_custom_role_id: custom_role.id,
        created_at: Time.current,
        updated_at: Time.current
      }

      expect do
        described_class.transaction(requires_new: true) do
          # Bypass model validation intentionally to verify the database check constraint.
          described_class.insert_all!([attributes]) # rubocop:disable Rails/SkipsModelValidations
        end
      end.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  it 'defaults new roles to legacy grant ownership' do
    expect(create(:access_role)).to be_legacy_grant_source
  end

  it 'cannot be destroyed while assigned to an account user' do
    access_role = create(:access_role)
    create(:account_user, account: access_role.account, access_role: access_role)

    expect { access_role.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
  end

  it 'cannot be destroyed while referenced by an inactive user snapshot' do
    access_role = create(:access_role)
    create(
      :account_user_lifecycle_snapshot,
      account: access_role.account,
      access_role: access_role
    )

    expect { access_role.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
  end
end
