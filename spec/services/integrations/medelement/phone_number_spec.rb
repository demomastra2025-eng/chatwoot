require 'rails_helper'

RSpec.describe Integrations::Medelement::PhoneNumber do
  describe '.normalize' do
    it 'normalizes Kazakhstan local, trunk and E.164 formats' do
      expect(described_class.normalize('701 123 45 67')).to eq('+77011234567')
      expect(described_class.normalize('8 (701) 123-45-67')).to eq('+77011234567')
      expect(described_class.normalize('+7 701 123 45 67')).to eq('+77011234567')
    end

    it 'rejects non-Kazakhstan and malformed phone numbers' do
      expect(described_class.normalize('+998 90 123 45 67')).to be_nil
      expect(described_class.normalize('123')).to be_nil
    end
  end

  describe '#query' do
    it 'builds the documented three-part Medelement phone query' do
      phone = described_class.new('+77011234567')

      expect(phone.query(skip: 100)).to eq(
        'patient_phone_2%5B0%5D=7&patient_phone_2%5B1%5D=701&patient_phone_2%5B2%5D=1234567&skip=100'
      )
    end
  end

  describe '#matches_patient?' do
    it 'matches documented provider formatting exactly' do
      phone = described_class.new('+77011234567')

      expect(phone.matches_patient?('PATIENT_PHONE_2' => '+7-X-701-X-1234567')).to be(true)
      expect(phone.matches_patient?('PHONES_STR' => '+7 701 0000000, +7 701 1234567')).to be(true)
      expect(phone.matches_patient?('PATIENT_PHONE_2' => '+7-X-701-X-1234568')).to be(false)
    end
  end
end
