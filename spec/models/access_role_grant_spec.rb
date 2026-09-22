require 'rails_helper'

RSpec.describe AccessRoleGrant do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:access_role).inverse_of(:grants) }
  end

  describe 'validations' do
    subject(:grant) { build(:access_role_grant) }

    it { is_expected.to validate_inclusion_of(:resource).in_array(described_class::RESOURCES) }
    it { is_expected.to validate_inclusion_of(:capability).in_array(described_class::CAPABILITIES) }
    it { is_expected.to validate_inclusion_of(:access_scope).in_array(described_class::ACCESS_SCOPES) }

    it 'rejects a role from another account' do
      grant.access_role = create(:access_role)

      expect(grant).not_to be_valid
      expect(grant.errors[:access_role]).to include('must belong to the same account')
    end

    it 'enforces account isolation at the database boundary' do
      source_account = create(:account)
      other_role = create(:access_role)
      attributes = {
        account_id: source_account.id,
        access_role_id: other_role.id,
        resource: 'contacts',
        capability: 'view',
        access_scope: 'own',
        created_at: Time.current,
        updated_at: Time.current
      }

      expect do
        described_class.transaction(requires_new: true) do
          # Bypass model validation intentionally to verify the tenant foreign key.
          described_class.insert_all!([attributes]) # rubocop:disable Rails/SkipsModelValidations
        end
      end.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it 'rejects a capability that is not supported by the resource' do
      grant.resource = 'contacts'
      grant.capability = 'complete_cancel'

      expect(grant).not_to be_valid
      expect(grant.errors[:capability]).to include('is not supported for this resource')
    end

    it 'allows only account-wide scopes for Automation management' do
      grant.resource = 'automation_rules'
      grant.capability = 'manage'
      grant.access_scope = 'team'

      expect(grant).not_to be_valid
      expect(grant.errors[:access_scope]).to include('is not supported for this resource')

      %w[none all].each do |access_scope|
        grant.access_scope = access_scope
        expect(grant).to be_valid
      end
    end

    it 'persists and audits an Automation management grant' do
      persisted_grant = create(
        :access_role_grant,
        account: grant.account,
        access_role: create(:access_role, account: grant.account),
        resource: 'automation_rules',
        capability: 'manage',
        access_scope: 'all'
      )

      expect do
        persisted_grant.update!(access_scope: 'none')
      end.to change(Audited::Audit.where(auditable: persisted_grant, action: 'update'), :count).by(1)
    end

    it 'allows only one grant per role, resource and capability' do
      existing = create(:access_role_grant)
      duplicate = build(
        :access_role_grant,
        account: existing.account,
        access_role: existing.access_role,
        resource: existing.resource,
        capability: existing.capability,
        access_scope: 'all'
      )

      expect(duplicate).not_to be_valid
    end
  end
end
