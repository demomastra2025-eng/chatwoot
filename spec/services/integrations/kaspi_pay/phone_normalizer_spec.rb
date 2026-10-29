# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::KaspiPay::PhoneNormalizer do
  describe '.to_kaspi_10_digits!' do
    it 'normalizes +7, 8, 11-digit, and 10-digit Kazakhstan phone numbers into exact 10-digit subscriber format' do
      expect(described_class.to_kaspi_10_digits!('+7 (701) 234-56-78')).to eq('7012345678')
      expect(described_class.to_kaspi_10_digits!('8 777 111 22 33')).to eq('7771112233')
      expect(described_class.to_kaspi_10_digits!('77051234567')).to eq('7051234567')
      expect(described_class.to_kaspi_10_digits!('7009876543')).to eq('7009876543')
    end

    it 'raises InvalidPhoneError for non-KZ or malformed phone numbers' do
      expect { described_class.to_kaspi_10_digits!('12345') }
        .to raise_error(described_class::InvalidPhoneError)
      expect { described_class.to_kaspi_10_digits!('+1 415 555 0199') }
        .to raise_error(described_class::InvalidPhoneError)
      expect { described_class.to_kaspi_10_digits!('') }
        .to raise_error(described_class::InvalidPhoneError)
    end
  end

  describe '.mask' do
    it 'masks middle digits while keeping operator prefix and last 2 digits' do
      expect(described_class.mask('+77012345678')).to eq('+7 701 *** ** 78')
      expect(described_class.mask('invalid')).to eq('***')
    end
  end
end
