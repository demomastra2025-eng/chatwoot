# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Contacts::PhoneNumberNormalizer do
  describe '.normalize' do
    it 'keeps compact e164 values as is' do
      expect(described_class.normalize('+77011234567')).to eq('+77011234567')
    end

    it 'normalizes Kazakhstan numbers using the default country' do
      expect(described_class.normalize('87011234567', default_country: 'KZ')).to eq('+77011234567')
    end

    it 'normalizes Kazakhstan numbers starting with 8 and formatting characters' do
      expect(described_class.normalize('8 (701) 123-45-67', default_country: 'KZ')).to eq('+77011234567')
    end

    it 'normalizes formatted numbers using the provided default country' do
      expect(described_class.normalize('(415) 555-2671', default_country: 'US')).to eq('+14155552671')
    end

    it 'normalizes international numbers that already include a plus sign' do
      expect(described_class.normalize('+7 701 123 4567')).to eq('+77011234567')
    end

    it 'returns nil for invalid values' do
      expect(described_class.normalize('whatsapp:7701')).to be_nil
    end

    it 'returns nil when a local number has no explicit country context' do
      expect(described_class.normalize('87011234567')).to be_nil
    end
  end
end
