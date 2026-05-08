require 'rails_helper'

RSpec.describe Scheduling::IntegerNumericNormalizer do
  describe '.normalize' do
    it 'accepts integer values and decimal zero values' do
      expect(described_class.normalize(1000, field_name: 'amount')).to eq(1000)
      expect(described_class.normalize(1000.0, field_name: 'amount')).to eq(1000)
      expect(described_class.normalize('1000', field_name: 'amount')).to eq(1000)
      expect(described_class.normalize('1000.0', field_name: 'amount')).to eq(1000)
      expect(described_class.normalize('1000.00', field_name: 'amount')).to eq(1000)
    end

    it 'rejects non-integer decimal values without truncating them' do
      expect { described_class.normalize(1000.5, field_name: 'amount') }
        .to raise_error(ArgumentError, 'amount must be an integer')
      expect { described_class.normalize('1000.50', field_name: 'amount') }
        .to raise_error(ArgumentError, 'amount must be an integer')
    end

    it 'rejects invalid numeric values' do
      expect { described_class.normalize(Float::INFINITY, field_name: 'amount') }
        .to raise_error(ArgumentError, 'amount must be an integer')
      expect { described_class.normalize('abc', field_name: 'amount') }
        .to raise_error(ArgumentError, 'amount must be an integer')
      expect { described_class.normalize('', field_name: 'amount') }
        .to raise_error(ArgumentError, 'amount must be an integer')
    end
  end

  describe '.normalize_or_zero' do
    it 'normalizes blank values to zero' do
      expect(described_class.normalize_or_zero('', field_name: 'amount')).to eq(0)
      expect(described_class.normalize_or_zero(nil, field_name: 'amount')).to eq(0)
    end
  end
end
