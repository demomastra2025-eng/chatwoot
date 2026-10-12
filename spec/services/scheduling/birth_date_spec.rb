require 'rails_helper'

RSpec.describe Scheduling::BirthDate do
  describe '.valid?' do
    it 'accepts existing calendar dates, including a leap day and the dashboard timestamp form' do
      [
        '1990-03-05', '2024-02-29', '2000-12-31', '1990-03-05T00:00:00.000Z', '1990-03-05T10:30:00+05:00', '1990-03-05T10:30',
        '1990-03-05T23:59:59-11:30', '1990-03-05T00:00:00+0530', '1990-03-05T00:00:00+05'
      ].each do |value|
        expect(described_class.valid?(value)).to be(true), value
      end
    end

    it 'rejects dates that do not exist, malformed text and non-strings' do
      [
        '2026-02-30', '2026-04-31', '2026-02-29', '1990-13-40', '1990-13-01', '1990-00-10', '1990-01-00', '1990-1-5',
        '20.07.1994', '19900305', 'abc', ' 1990-03-05', '1990-03-05 ', '1990-03-05T', { 'year' => 1990 }, 1990, true
      ].each do |value|
        expect(described_class.valid?(value)).to be(false), value.inspect
      end
    end

    it 'rejects a time part with an impossible time of day or UTC offset, and a space instead of the T' do
      [
        '1990-03-15T99:99:99Z', '1990-05-01T25:99:00Z', '1990-05-01T24:00:00Z', '1990-05-01T10:60:00Z', '1990-05-01T10:30:60Z',
        '1990-05-01T00:00:00+99:99', '1990-05-01T00:00:00+24:00', '1990-05-01T00:00:00+05:60', '1990-05-01T00:00:00Z+05:00',
        '1990-05-01 00:00:00', '1990-03-05 10:30', '1990-05-01T00:00:00.Z'
      ].each do |value|
        expect(described_class.valid?(value)).to be(false), value
      end
    end

    it 'takes only the plain date when asked to' do
      expect(described_class.valid?('1990-03-05', plain: true)).to be(true)
      ['1990-03-05T00:00:00.000Z', '1990-03-05T10:30', '2026-02-30'].each do |value|
        expect(described_class.valid?(value, plain: true)).to be(false), value
      end
    end
  end

  describe '.validate!' do
    it 'passes an absent or empty value so the field can stay unset or be cleared' do
      expect(described_class.validate!(nil)).to be_nil
      expect(described_class.validate!('')).to eq('')
    end

    it 'returns a valid value unchanged' do
      expect(described_class.validate!('1990-03-05')).to eq('1990-03-05')
    end

    it 'raises a 422 that names the field' do
      expect { described_class.validate!('2026-02-30') }.to raise_error(Scheduling::Error) do |error|
        expect(error).to have_attributes(code: 'INVALID_BIRTH_DATE', status: 422)
        expect(error.message).to include('birth_date', 'YYYY-MM-DD')
        expect(error.details).to eq(field: 'birth_date', reason: 'invalid_birth_date')
      end
      expect { described_class.validate!('x', field: 'custom_attributes.birth_date') }
        .to raise_error(Scheduling::Error, /custom_attributes\.birth_date/)
    end

    it 'rejects whitespace-only text instead of treating it as empty' do
      expect { described_class.validate!('  ') }.to raise_error(Scheduling::Error)
    end

    it 'refuses a time part for the plain date parameter' do
      expect(described_class.validate!('1990-03-05', plain: true)).to eq('1990-03-05')
      expect { described_class.validate!('1990-03-05T00:00:00Z', plain: true) }.to raise_error(Scheduling::Error)
    end
  end

  describe '.validate_attributes!' do
    it 'checks only the birth_date entry, with string or symbol keys and permitted parameters' do
      expect(described_class.validate_attributes!({ 'birth_date' => '1990-03-05', 'other' => 'x' })).to include('other' => 'x')
      expect(described_class.validate_attributes!({ other: 'not a date' })).to eq(other: 'not a date')
      expect { described_class.validate_attributes!({ 'birth_date' => '1990-13-40' }) }
        .to raise_error(Scheduling::Error, /custom_attributes\.birth_date/)
      expect { described_class.validate_attributes!({ birth_date: '2026-02-30' }) }.to raise_error(Scheduling::Error)
      permitted = ActionController::Parameters.new(birth_date: '2026-04-31').permit(:birth_date)
      expect { described_class.validate_attributes!(permitted) }.to raise_error(Scheduling::Error)
    end

    it 'ignores payloads that are not hashes' do
      expect(described_class.validate_attributes!(nil)).to be_nil
      expect(described_class.validate_attributes!('{"birth_date":"x"}')).to eq('{"birth_date":"x"}')
    end

    it 'lets the value a card already holds through, so a legacy card stays editable, but not a different bad one' do
      current = { 'birth_date' => '2026-02-30' }

      expect(described_class.validate_attributes!({ 'birth_date' => '2026-02-30' }, current: current)).to eq('birth_date' => '2026-02-30')
      expect { described_class.validate_attributes!({ 'birth_date' => '2026-02-31' }, current: current) }.to raise_error(Scheduling::Error)
      expect { described_class.validate_attributes!({ 'birth_date' => '2026-02-30' }, current: {}) }.to raise_error(Scheduling::Error)
    end
  end

  describe '.nonexistent_date?' do
    it 'is true for a value written as a calendar date that does not exist' do
      ['1990-02-30', '30.02.1990', '31.04.1990', '29.02.2023', '1990-13-40', '1990-02-30T00:00:00Z', '1990-02-30 00:00:00'].each do |value|
        expect(described_class.nonexistent_date?(value)).to be(true), value
      end
    end

    it 'is false for an existing date, for any form of it, and for text that is not a calendar date' do
      ['1990-03-05', '1990-03-05T00:00:00.000Z', '20.07.1994', '29.02.2024', '1990-03-05 00:00:00',
       '5/3/1990', '5 March 1990', 'x', 5, nil].each do |value|
        expect(described_class.nonexistent_date?(value)).to be(false), value.inspect
      end
    end
  end

  describe '.normalize' do
    it 'reduces a valid value to its calendar date and returns anything else as it is' do
      expect(described_class.normalize('1990-03-05T00:00:00.000Z')).to eq('1990-03-05')
      expect(described_class.normalize('1990-03-05')).to eq('1990-03-05')
      expect(described_class.normalize('1990-02-30T00:00:00Z')).to eq('1990-02-30T00:00:00Z')
      expect(described_class.normalize('20.07.1994')).to eq('20.07.1994')
      expect(described_class.normalize(nil)).to be_nil
    end
  end
end
