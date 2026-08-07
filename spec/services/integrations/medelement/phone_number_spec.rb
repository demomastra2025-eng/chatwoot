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

  describe '.patient_phones' do
    it 'normalizes every documented provider phone field and removes duplicates' do
      first_phone = ['+7', '701', '123', '4567'].join
      second_phone = ['+7', '777', '111', '2233'].join
      third_phone = ['+7', '700', '999', '8877'].join
      patient = {
        'PATIENT_PHONE_2_STR' => first_phone,
        'PATIENT_PHONE_1' => '8 (777) 111-22-33',
        'PATIENT_PHONE_4_STR' => first_phone,
        'PHONES_STR' => third_phone
      }

      expect(described_class.patient_phones(patient)).to eq([first_phone, second_phone, third_phone])
    end
  end

  describe '.contact_phones' do
    it 'returns the normalized primary and secondary Contact numbers in stable order' do
      primary_phone = ['+7', '701', '123', '4567'].join
      secondary_phone = ['+7', '777', '111', '2233'].join
      contact = instance_double(
        Contact,
        phone_number: '+7 701 123 45 67',
        custom_attributes: { 'secondary_phones' => ['8 (777) 111-22-33', primary_phone] }
      )

      expect(described_class.contact_phones(contact)).to eq([primary_phone, secondary_phone])
    end
  end
end
