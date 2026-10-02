require 'rails_helper'

RSpec.describe WhatsappUsageExchangeRate do
  let(:attributes) do
    {
      month_start: Date.new(2026, 11, 1),
      requested_date: Date.new(2026, 11, 1),
      effective_date: Date.new(2026, 11, 1),
      rate_per_usd: BigDecimal('499.3'),
      nominal_rate: BigDecimal(49_930),
      nominal_units: 100,
      status: 'fetched',
      source_url: 'https://nationalbank.kz/rss/get_rates.cfm?fdate=01.11.2026',
      fetched_at: Time.utc(2026, 11, 1)
    }
  end

  it 'accepts a complete positive monthly snapshot' do
    expect(described_class.new(attributes)).to be_valid
  end

  it 'requires the report date and requested date to be the first day of the same month' do
    record = described_class.new(attributes.merge(month_start: Date.new(2026, 11, 2)))

    expect(record).not_to be_valid
    expect(record.errors[:month_start]).to be_present
  end

  it 'rejects non-positive rates and nominal units' do
    record = described_class.new(attributes.merge(rate_per_usd: 0, nominal_rate: 0, nominal_units: 0))

    expect(record).not_to be_valid
    expect(record.errors[:rate_per_usd]).to be_present
    expect(record.errors[:nominal_rate]).to be_present
    expect(record.errors[:nominal_units]).to be_present
  end

  it 'does not allow a fetched snapshot to be changed' do
    record = described_class.create!(attributes)

    expect { record.update!(rate_per_usd: BigDecimal(500)) }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
