require 'rails_helper'

RSpec.describe Scheduling::InputValidation do
  def failure
    yield
    nil
  rescue Scheduling::Error => e
    e
  end

  describe '.datetime' do
    it 'reads equivalent UTC and +05:00 inputs as the same instant' do
      expect(described_class.datetime('2031-10-13T19:00:00Z', field_name: 'from'))
        .to eq(described_class.datetime('2031-10-14T00:00:00+05:00', field_name: 'from'))
      expect(described_class.datetime('2031-10-14T00:00:00+0500', field_name: 'from')).to eq(Time.utc(2031, 10, 13, 19))
    end

    it 'refuses a UTC offset that does not exist instead of dropping it and reading the instant as UTC' do
      ['2031-10-14T00:00:00+25:00', '2031-10-14T00:00:00+05:99', '2031-10-14T00:00:00-24:00', '2031-10-14T00:00:00+99'].each do |value|
        error = failure { described_class.datetime(value, field_name: 'starts_at') }

        expect(error).to have_attributes(code: 'INVALID_DATE', status: 422, details: { field: 'starts_at', reason: 'invalid_date' }), value
      end
    end

    it 'refuses a non-existent day and an impossible time of day' do
      ['2031-11-31', '2031-02-30T00:00:00Z', '2031-10-14T25:00:00Z', 'tomorrow', ''].each do |value|
        expect(failure { described_class.datetime(value, field_name: 'from') }).to have_attributes(code: 'INVALID_DATE'), value
      end
    end
  end

  describe '.parse_date' do
    it 'reads an existing day written as YYYY-MM-DD' do
      expect(described_class.parse_date('2031-10-14')).to eq(Date.new(2031, 10, 14))
      expect(described_class.parse_date(' 2024-02-29 ')).to eq(Date.new(2024, 2, 29))
    end

    it 'does not complete, reinterpret or move anything else' do
      ['2031-10', '31-10-14', '60-05-01', '2031-11-31', '2031-02-30', '2031-13-01', '2031-10-14T00:00:00Z', '14.10.2031', '20311014', 'abc', nil, 5]
        .each do |value|
          expect(described_class.parse_date(value)).to be_nil, value.inspect
        end
    end
  end

  describe '.date' do
    it 'returns the day or raises a 422 that names the field' do
      expect(described_class.date('2031-10-14', field_name: 'date')).to eq(Date.new(2031, 10, 14))

      error = failure { described_class.date('2031-10', field_name: 'date_from') }

      expect(error).to have_attributes(code: 'INVALID_DATE', status: 422, details: { field: 'date_from', reason: 'invalid_date' })
      expect(error.message).to include('date_from must be an existing calendar date')
    end
  end
end
