require 'rails_helper'

RSpec.describe Crm::AmountFormatter do
  describe '.major_from_minor' do
    it 'formats minor units as AI-facing major units without redundant trailing decimals' do
      expect(described_class.major_from_minor(20_000)).to eq('200')
      expect(described_class.major_from_minor(20_050)).to eq('200.5')
      expect(described_class.major_from_minor(0)).to eq('0')
    end
  end

  describe '.minor_from_major' do
    it 'parses whole-number AI-facing major units into CRM storage minor units' do
      expect(described_class.minor_from_major('200.00')).to eq(20_000)
      expect(described_class.minor_from_major('200')).to eq(20_000)
      expect(described_class.minor_from_major('200,00')).to eq(20_000)
    end

    it 'rejects fractional major units' do
      expect { described_class.minor_from_major('200.50') }
        .to raise_error(ArgumentError, 'amount must be a whole number in major units')
      expect { described_class.minor_from_major('200,50') }
        .to raise_error(ArgumentError, 'amount must be a whole number in major units')
    end
  end
end
