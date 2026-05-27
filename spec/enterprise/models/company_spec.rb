require 'rails_helper'

RSpec.describe Company, type: :model do
  context 'with validations' do
    it { is_expected.to validate_presence_of(:account_id) }
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(100) }
    it { is_expected.to validate_length_of(:description).is_at_most(1000) }

    it 'normalizes non-hash profile attributes to empty hashes' do
      company = build(:company, additional_attributes: [], custom_attributes: 'bad')
      company.validate

      expect(company.additional_attributes).to eq({})
      expect(company.custom_attributes).to eq({})
    end

    describe 'domain validation' do
      it { is_expected.to allow_value('example.com').for(:domain) }
      it { is_expected.to allow_value('sub.example.com').for(:domain) }
      it { is_expected.to allow_value('').for(:domain) }
      it { is_expected.to allow_value(nil).for(:domain) }
      it { is_expected.not_to allow_value('invalid-domain').for(:domain) }
      it { is_expected.not_to allow_value('.example.com').for(:domain) }
    end
  end

  context 'with associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to have_many(:crm_deals).class_name('Crm::Deal').dependent(:nullify) }
    it { is_expected.to have_many(:contacts).dependent(:nullify) }
  end

  describe 'domain normalization' do
    let(:account) { create(:account) }

    it 'normalizes blank domain to nil before validation' do
      company = build(:company, account: account, domain: '   ')

      company.validate

      expect(company.domain).to be_nil
    end

    it 'strips and downcases domain before validation' do
      company = build(:company, account: account, domain: '  EXAMPLE.COM ')

      company.validate

      expect(company.domain).to eq('example.com')
    end
  end

  describe 'activity rollup' do
    let(:company) { create(:company) }

    it 'records newer activity timestamps' do
      activity_at = 1.hour.ago

      company.record_activity_at!(activity_at)

      expect(company.reload.last_activity_at.to_i).to eq(activity_at.to_i)
    end

    it 'skips noisy updates inside the rollup interval' do
      company.update!(last_activity_at: Time.zone.now)
      original_activity = company.last_activity_at

      company.record_activity_at!(1.minute.ago)

      expect(company.reload.last_activity_at.to_i).to eq(original_activity.to_i)
    end
  end

  describe 'scopes' do
    let(:account) { create(:account) }
    let!(:company_b) { create(:company, name: 'B Company', account: account) }
    let!(:company_a) { create(:company, name: 'A Company', account: account) }
    let!(:company_c) { create(:company, name: 'C Company', account: account) }

    describe '.ordered_by_name' do
      it 'orders companies by name alphabetically' do
        companies = described_class.where(account: account).ordered_by_name
        expect(companies.map(&:name)).to eq([company_a.name, company_b.name, company_c.name])
      end
    end
  end
end
