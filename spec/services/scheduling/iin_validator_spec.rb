require 'rails_helper'

RSpec.describe Scheduling::IinValidator do
  describe '.in_use?' do
    it 'is true for an account whose contact attributes hold an IIN, false for any other account and for none' do
      account = create(:account)
      account.enable_features!('scheduling')

      expect(described_class.in_use?(account)).to be(false)
      expect(described_class.in_use?(nil)).to be(false)
      create(:custom_attribute_definition, account: account, attribute_key: 'iin', attribute_model: :conversation_attribute)
      create(:custom_attribute_definition, account: create(:account), attribute_key: 'iin', attribute_model: :contact_attribute)
      expect(described_class.in_use?(account)).to be(false)
      create(:custom_attribute_definition, account: account, attribute_key: 'iin', attribute_model: :contact_attribute)
      expect(described_class.in_use?(account)).to be(true)
    end
  end

  describe '.personal_iin?' do
    it 'returns true for valid 20th- and 21st-century Kazakhstan personal IINs' do
      expect(described_class.personal_iin?('940720300129')).to be(true)
      expect(described_class.personal_iin?('900101 300027')).to be(true)
      expect(described_class.personal_iin?('050505-500126')).to be(true)
    end

    it 'returns false for invalid checksums, company BINs, future dates and phone numbers' do
      expect(described_class.personal_iin?('940720300128')).to be(false)
      expect(described_class.personal_iin?('180540000121')).to be(false)
      expect(described_class.personal_iin?('180540300120')).to be(false)
      expect(described_class.personal_iin?('850505-501230')).to be(false)
      expect(described_class.personal_iin?('380501500122')).to be(false)
      expect(described_class.personal_iin?('+77011234567')).to be(false)
      expect(described_class.personal_iin?(nil)).to be(false)
    end
  end

  describe '.redact_text' do
    it 'redacts contiguous, spaced and hyphenated personal IINs with [ИИН СКРЫТ]' do
      expect(described_class.redact_text('Пациент 940720300129 записан')).to eq('Пациент [ИИН СКРЫТ] записан')
      expect(described_class.redact_text('Карта: 940720 300129.')).to eq('Карта: [ИИН СКРЫТ].')
      expect(described_class.redact_text('Карта: 940720 300 129.')).to eq('Карта: [ИИН СКРЫТ].')
      expect(described_class.redact_text('Карта: 940720-300129.')).to eq('Карта: [ИИН СКРЫТ].')
      expect(described_class.redact_text('Карта: 9407 2030 0129.')).to eq('Карта: [ИИН СКРЫТ].')
    end

    it 'redacts labeled ИИН/ЖСН/IIN/medelement_iin values even when the patient made a check-digit typo' do
      expect(described_class.redact_text('Мой ИИН: 900101300123, проверьте')).to eq('Мой ИИН: [ИИН СКРЫТ], проверьте')
      expect(described_class.redact_text('ЖСН 900101 300123')).to eq('ЖСН [ИИН СКРЫТ]')
      expect(described_class.redact_text('IIN - 900101-300123')).to eq('IIN - [ИИН СКРЫТ]')
      expect(described_class.redact_text('{"iin":"900101300123","medelement_iin": "900101300123"}'))
        .to eq('{"iin":"[ИИН СКРЫТ]","medelement_iin": "[ИИН СКРЫТ]"}')
      expect(described_class.redact_text('{\"iin\":\"900101300123\"}')).to eq('{\"iin\":\"[ИИН СКРЫТ]\"}')
      expect(described_class.redact_text('data: клиент 940720300129')).to eq('data: клиент [ИИН СКРЫТ]')
    end

    it 'redacts an IIN placed next to a date or a phone number while keeping the date and phone intact' do
      expect(described_class.redact_text('29.10.2026 940720300129')).to eq('29.10.2026 [ИИН СКРЫТ]')
      expect(described_class.redact_text('+77011234567 940720-300129')).to eq('+77011234567 [ИИН СКРЫТ]')
      expect(described_class.redact_text('+7 701 123 45 67, 940720300129')).to eq('+7 701 123 45 67, [ИИН СКРЫТ]')
    end

    it 'leaves phone numbers, 16-digit payment cards, company BINs and data URIs untouched' do
      unchanged = [
        'Телефон +7 701 123 45 67 или 8 701 123 45 67',
        'Международный +998901234567 и +380501500122',
        'Kaspi карта 4400 4301 2345 6789 или 4400-4301-2345-6789 или 4400430123456789',
        'БИН клиники 180540000121 / 180540300120',
        'data:image/jpeg;base64,940720300129AAAA'
      ]

      unchanged.each do |sample|
        expect(described_class.redact_text(sample)).to eq(sample)
      end
    end
  end

  describe '.sanitize_identifier and .sanitize_custom_attributes' do
    it 'drops 12-digit numeric identifiers and iin/medelement_iin keys while keeping external non-IIN codes' do
      expect(described_class.sanitize_identifier('940720300129')).to be_nil
      expect(described_class.sanitize_identifier('900101 300123')).to be_nil
      expect(described_class.sanitize_identifier('CARD-42')).to eq('CARD-42')
      expect(described_class.sanitize_identifier('card 940720300129')).to eq('card [ИИН СКРЫТ]')

      sanitized = described_class.sanitize_custom_attributes(
        'iin' => '940720300129',
        'medelement_iin' => '900101300123',
        'medelement_patient_code' => 'ME-77',
        'note' => 'Пациент 940720300129'
      )
      expect(sanitized).to eq('medelement_patient_code' => 'ME-77', 'note' => 'Пациент [ИИН СКРЫТ]')
    end
  end

  describe '.require_valid_in!' do
    it 'checks the identifier and the iin of the custom attributes, given as a hash with symbol or string keys or as JSON text' do
      expect(described_class.require_valid_in!(identifier: ' 900101 300027')).to eq('900101300027')
      expect(described_class.require_valid_in!(custom_attributes: { iin: '900101300027', vip: true })).to be_nil
      expect(described_class.require_valid_in!(custom_attributes: { 'iin' => '900101300027' }, identifier: '900101300027')).to eq('900101300027')
      expect(described_class.require_valid_in!(custom_attributes: '{"iin": "900101300027"}')).to be_nil
      expect(described_class.require_valid_in!(custom_attributes: 'not json')).to be_nil
      expect(described_class.require_valid_in!).to be_nil
    end

    it 'refuses a wrong iin of the custom attributes even when the identifier is right' do
      [{ iin: '87011234567' }, { 'iin' => 'abc' }, '{"iin": "900101300028"}'].each do |attributes|
        expect { described_class.require_valid_in!(identifier: '900101300027', custom_attributes: attributes) }
          .to raise_error(Scheduling::Error, /Invalid IIN/), attributes.inspect
      end
    end
  end

  describe '.require_valid!' do
    it 'gives the digits of an IIN of 12 digits with the check digit, whatever the spaces and dashes' do
      expect(described_class.require_valid!('900101300027')).to eq('900101300027')
      expect(described_class.require_valid!(' 900101 300027 ')).to eq('900101300027')
      expect(described_class.require_valid!('900101-300027')).to eq('900101300027')
      expect(described_class.require_valid!('850505501230')).to eq('850505501230')
    end

    it 'has nothing to write for a missing or blank value' do
      expect(described_class.require_valid!(nil)).to be_nil
      expect(described_class.require_valid!('')).to be_nil
      expect(described_class.require_valid!("  \n")).to be_nil
    end

    # Suggestion eval 27.10 (c74-1245386): a payment phone number the patient sent was read as the ID number.
    it 'refuses a phone number, a number of the wrong length, a wrong check digit and text, and says why' do
      ['+7 701 123 45 67', '87011234567', '77011234567', '7011234567', '90010130002', '9001013000271', '900101300028', 'abc',
       'Kaspi 7011234567'].each do |value|
        expect { described_class.require_valid!(value) }
          .to raise_error(Scheduling::Error, /Invalid IIN: an IIN is 12 digits with a check digit, a phone number is not an IIN/), value
      end
    end

    it 'raises the error code of the other IIN checks' do
      expect { described_class.require_valid!('87011234567') }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('INVALID_IIN') }
    end
  end
end
