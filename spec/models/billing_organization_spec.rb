require 'rails_helper'

RSpec.describe BillingOrganization do
  describe 'associations' do
    it { is_expected.to have_many(:accounts).dependent(:restrict_with_error) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:name) }
  end

  describe 'status' do
    it { is_expected.to define_enum_for(:status).with_values(active: 0, suspended: 1) }
  end

  it 'cannot be destroyed while it owns workspaces' do
    organization = create(:billing_organization)
    create(:account, billing_organization: organization)

    expect(organization.destroy).to be(false)
    expect(organization.errors[:base]).to be_present
  end
end
