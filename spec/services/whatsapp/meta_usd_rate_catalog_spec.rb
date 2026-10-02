require 'rails_helper'

RSpec.describe Whatsapp::MetaUsdRateCatalog do
  describe '.rate' do
    it 'returns the official published base rate as a BigDecimal for the effective quarter' do
      rate = described_class.rate(country_code: 'KZ', category: 'marketing', at: Date.new(2026, 10, 1))

      expect(rate).to be_a(BigDecimal)
      expect(rate).to eq(BigDecimal('0.0604'))
    end

    it 'uses the correct shared market for NANP territories and valid ISO codes in Other' do
      expect(
        described_class.rate(country_code: 'DO', category: 'marketing', at: Date.new(2026, 10, 1))
      ).to eq(BigDecimal('0.074'))
      expect(
        described_class.rate(country_code: 'JM', category: 'marketing', at: Date.new(2026, 10, 1))
      ).to eq(BigDecimal('0.074'))
      expect(
        described_class.rate(country_code: 'PR', category: 'marketing', at: Date.new(2026, 10, 1))
      ).to eq(BigDecimal('0.074'))
      expect(
        described_class.rate(country_code: 'BQ', category: 'marketing', at: Date.new(2026, 10, 1))
      ).to eq(BigDecimal('0.0604'))
    end

    it 'does not infer international authentication rates for markets whose card lists n/a' do
      expect(
        described_class.rate(country_code: 'KZ', category: 'authentication-international', at: Date.new(2026, 10, 1))
      ).to eq(BigDecimal('0.16'))
      expect(
        described_class.rate(country_code: 'US', category: 'authentication_international', at: Date.new(2026, 10, 1))
      ).to be_nil
    end

    it 'returns nil before the rate card effective date and at the next quarter boundary' do
      expect(described_class.rate(country_code: 'KZ', category: 'marketing', at: Date.new(2026, 9, 30))).to be_nil
      expect(described_class.rate(country_code: 'KZ', category: 'marketing', at: Date.new(2027, 1, 1))).to be_nil
    end

    it 'compares timestamp inputs by their UTC calendar date' do
      before_start_in_utc = Time.new(2026, 10, 1, 0, 30, 0, '+02:00')
      expect(described_class.rate(country_code: 'KZ', category: 'marketing', at: before_start_in_utc)).to be_nil
    end

    it 'returns nil for unknown markets and categories without a published rate' do
      expect(described_class.rate(country_code: 'ZZ', category: 'marketing', at: Date.new(2026, 10, 1))).to be_nil
      expect(described_class.rate(country_code: 'AN', category: 'marketing', at: Date.new(2026, 10, 1))).to be_nil
      expect(described_class.rate(country_code: 'KZ', category: 'not-a-category', at: Date.new(2026, 10, 1))).to be_nil
    end
  end
end
