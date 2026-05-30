require 'rails_helper'

RSpec.describe Captain::Tools::InputNormalizer do
  describe '.optional_positive_id' do
    it 'treats blank, invalid, zero, and negative values as omitted ID selectors' do
      [nil, '', ' ', 0, '0', -1, '-4', 'abc'].each do |value|
        expect(described_class.optional_positive_id(value)).to be_nil
      end
    end

    it 'returns positive integer IDs from numeric strings or numbers' do
      expect(described_class.optional_positive_id(12)).to eq(12)
      expect(described_class.optional_positive_id('12')).to eq(12)
      expect(described_class.optional_positive_id(' 2 ')).to eq(2)
      expect(described_class.optional_positive_id('+5')).to eq(5)
      expect(described_class.optional_positive_id(5.0)).to eq(5)
    end

    it 'does not coerce decimal-like selector values into database IDs' do
      expect(described_class.optional_positive_id(5.1)).to be_nil
      expect(described_class.optional_positive_id('2.0')).to be_nil
    end

    it 'unwraps provider tool call envelopes before coercing IDs' do
      expect(
        described_class.optional_positive_id(
          'name' => 'get_deal',
          'parameters' => { 'deal_id' => '52' }
        )
      ).to eq(52)
    end
  end

  describe '.required_positive_id' do
    it 'raises a clear validation error for omitted or invalid ID selectors' do
      expect { described_class.required_positive_id(0, field_name: 'deal_id') }
        .to raise_error(ArgumentError, 'deal_id is required')
    end
  end
end
