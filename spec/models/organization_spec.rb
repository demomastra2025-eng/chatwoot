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

    it 'accepts exactly 12 digits with the right control digit' do
      expect(build(:organization, bin: '980140000124')).to be_valid
    end

    it 'strips the spaces it was typed with' do
      organization = create(:organization, bin: ' 9801 4000 0124 ')

      expect(organization.bin).to eq('980140000124')
    end

    %w[98014000012 9801400001244 98014000012a 9801-4000-0123 БИН].each do |value|
      it "refuses #{value.inspect}" do
        organization = build(:organization, bin: value)

        expect(organization).not_to be_valid
        expect(organization.errors[:bin]).to eq(['должен состоять из 12 цифр'])
      end
    end

    describe 'the control digit' do
      # The reference calculation, written out on its own: weights 1..11 over the first 11 digits, modulo 11
      def reference_control(first_eleven, weights)
        first_eleven.each_char.with_index.sum { |char, index| char.to_i * weights.fetch(index) } % 11
      end

      def with_control(first_eleven)
        control = reference_control(first_eleven, (1..11).to_a)
        control = reference_control(first_eleven, [3, 4, 5, 6, 7, 8, 9, 10, 11, 1, 2]) if control == 10
        control == 10 ? nil : "#{first_eleven}#{control}"
      end

      it 'is the remainder of the first pass when it is below 10' do
        # 9*1 + 8*2 + 0*3 + 1*4 + 4*5 + 1*10 + 2*11 = 81, 81 mod 11 = 4
        expect(with_control('98014000012')).to eq('980140000124')
        expect(build(:organization, bin: '980140000124')).to be_valid
        expect(build(:organization, bin: '980140000123')).not_to be_valid
      end

      it 'is counted again with the shifted weights when the first pass leaves 10' do
        # the 10th digit 1 weighs 10 in the first pass (remainder 10) and 1 in the second pass
        expect(reference_control('00000000010', (1..11).to_a)).to eq(10)
        expect(with_control('00000000010')).to eq('000000000101')
        expect(build(:organization, bin: '000000000101')).to be_valid
        expect(build(:organization, bin: '000000000100')).not_to be_valid
        expect(build(:organization, bin: '000000000104')).not_to be_valid
      end

      it 'accepts a БИН that starts with zeros' do
        # 7*4 + 4*5 + 7*10 + 2*11 = 140, 140 mod 11 = 8
        expect(build(:organization, bin: '000740000728')).to be_valid
      end

      it 'does not exist when both passes leave 10, so no 12th digit makes such a БИН valid' do
        expect(with_control('00000000281')).to be_nil

        (0..9).each do |last|
          organization = build(:organization, bin: "00000000281#{last}")

          expect(organization).not_to be_valid
          expect(organization.errors[:bin]).to eq(['указан неверно: не совпадает контрольная цифра'])
        end
      end

      it 'refuses every wrong 12th digit and accepts only the right one' do
        valid = with_control('98014000012')

        results = (0..9).to_h { |last| ["98014000012#{last}", build(:organization, bin: "98014000012#{last}").valid?] }

        expect(results.select { |_bin, ok| ok }.keys).to eq([valid])
      end

      it 'says the БИН is wrong, in Russian' do
        organization = build(:organization, bin: '980140000123')
        organization.valid?

        expect(organization.errors[:bin]).to eq(['указан неверно: не совпадает контрольная цифра'])
        expect(organization.errors.full_messages).to eq(['БИН указан неверно: не совпадает контрольная цифра'])
      end

      it 'is not checked for a number of the wrong shape, which gets the message about the shape only' do
        organization = build(:organization, bin: '98014000012')
        organization.valid?

        expect(organization.errors[:bin]).to eq(['должен состоять из 12 цифр'])
      end

      it 'is calculated by Organization.bin_control_digit' do
        expect(described_class.bin_control_digit('98014000012')).to eq(4)
        expect(described_class.bin_control_digit('00000000010')).to eq(1)
        expect(described_class.bin_control_digit('00000000281')).to be_nil
      end

      it 'is valid in every БИН the factory makes' do
        organizations = create_list(:organization, 25, :with_requisites)

        expect(organizations.map(&:bin).uniq.size).to eq(25)
        expect(organizations).to all(be_valid)
      end
    end

    it 'is unique when it is present' do
      create(:organization, bin: '980140000124')
      duplicate = build(:organization, bin: '980140000124')

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:bin]).to eq(['уже указан у другой организации'])
    end

    it 'has a unique index, so a race cannot store a duplicate' do
      create(:organization, bin: '980140000124')

      expect { build(:organization, bin: '980140000124').save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
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
