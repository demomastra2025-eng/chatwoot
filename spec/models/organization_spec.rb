# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Organization do
  it { is_expected.to have_many(:accounts).dependent(:restrict_with_error) }

  describe 'validations' do
    it 'needs a name' do
      organization = build(:organization, name: '  ')

      expect(organization).not_to be_valid
      expect(organization.errors[:name]).to be_present
    end

    it 'is valid with a name alone' do
      expect(build(:organization)).to be_valid
    end

    it 'keeps the name short' do
      expect(build(:organization, name: 'я' * 256)).not_to be_valid
    end

    it 'is valid with every requisite filled in' do
      expect(build(:organization, :with_requisites)).to be_valid
    end
  end

  describe 'the BIN' do
    it 'is optional' do
      expect(build(:organization, bin: nil)).to be_valid
    end

    it 'stores a blank BIN as nil, so any number of organizations may have none' do
      first = create(:organization, bin: '')
      second = create(:organization, bin: '   ')

      expect([first.bin, second.bin]).to eq([nil, nil])
    end

    it 'accepts exactly 12 digits' do
      expect(build(:organization, bin: '980140000123')).to be_valid
    end

    it 'strips the spaces it was typed with' do
      organization = create(:organization, bin: ' 9801 4000 0123 ')

      expect(organization.bin).to eq('980140000123')
    end

    %w[98014000012 9801400001234 98014000012a 9801-4000-0123 БИН].each do |value|
      it "refuses #{value.inspect}" do
        organization = build(:organization, bin: value)

        expect(organization).not_to be_valid
        expect(organization.errors[:bin]).to eq(['должен состоять из 12 цифр'])
      end
    end

    it 'is unique when it is present' do
      create(:organization, bin: '980140000123')
      duplicate = build(:organization, bin: '980140000123')

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:bin]).to eq(['уже указан у другой организации'])
    end

    it 'has a unique index, so a race cannot store a duplicate' do
      create(:organization, bin: '980140000123')

      expect { build(:organization, bin: '980140000123').save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe 'the other requisites' do
    it 'squishes the name and drops blank optional values' do
      organization = create(:organization, name: "  ТОО   Алатау \n", legal_name: ' ', phone: '', address: "\n", notes: ' ')

      expect(organization.name).to eq('ТОО Алатау')
      expect([organization.legal_name, organization.phone, organization.address, organization.notes]).to all(be_nil)
    end

    it 'checks the e-mail for billing' do
      expect(build(:organization, billing_email: 'not-an-email')).not_to be_valid
      expect(build(:organization, billing_email: 'billing@example.test')).to be_valid
      expect(build(:organization, billing_email: nil)).to be_valid
    end

    it 'starts with empty custom attributes' do
      expect(create(:organization).custom_attributes).to eq({})
    end
  end

  describe 'deleting' do
    it 'is refused while accounts are linked, and the accounts stay linked' do
      organization = create(:organization)
      account = create(:account, organization: organization)

      expect(organization.destroy).to be(false)
      expect(organization.errors[:base]).to be_present
      expect(described_class.exists?(organization.id)).to be(true)
      expect(account.reload.organization).to eq(organization)
    end

    it 'works once the accounts are unlinked' do
      organization = create(:organization)
      account = create(:account, organization: organization)
      account.update!(organization: nil)

      expect(organization.destroy).to be_truthy
      expect(described_class.exists?(organization.id)).to be(false)
    end
  end

  describe 'an account' do
    it 'works without an organization' do
      account = create(:account)

      expect(account.organization).to be_nil
      expect(account).to be_valid
    end

    it 'belongs to at most one organization' do
      organization = create(:organization)
      account = create(:account, organization: organization)

      expect(organization.accounts).to eq([account])
    end
  end
end
